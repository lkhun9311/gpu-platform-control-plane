"""Two-rank gloo DDP whose arithmetic is checkable by hand.

This exists to answer one question with evidence rather than with a screenshot: did gradient synchronisation
actually happen? A loss that goes down does not answer it -- a single rank's loss also goes down, and two
ranks that never talk both report a falling loss while diverging from each other.

So the model is one scalar weight and the data is chosen so the correct synchronised answer is a number a
reader can verify without running anything:

    w starts at 0, x = 1, and the two ranks are given different targets, y = 1 and y = 3.
    loss = (w*x - y)^2, so dL/dw = 2*(w*x - y)*x, which is -2 on rank 0 and -6 on rank 1.
    DDP averages them: -4. One SGD step at lr=0.1 gives w = 0 - 0.1*(-4) = 0.4 on BOTH ranks.

0.4 is therefore the signature of a working all-reduce. Without synchronisation rank 0 lands on 0.2 and rank
1 on 0.6, which is the control this script can also produce (DDP_NO_SYNC=1) so that the check is shown to be
capable of failing.

Every claim the write-up makes is emitted here as a JSONL record, one object per line, so the analysis reads
the run rather than the console.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import socket
import sys
import time

import torch
import torch.distributed as dist
import torch.nn as nn
from torch.nn.parallel import DistributedDataParallel as DDP

# The pre-registered tolerance.
#
# Fixed here, in the code, before the run -- not chosen after seeing the numbers. gloo all-reduce on float32
# is deterministic for two values, so this is slack for accumulation order rather than a fitted threshold.
TOLERANCE = 1e-6

# What a synchronised step must produce, derived from the world size rather than pinned to two ranks.
#
# The constants used to be -4.0 and 0.4, which are correct for exactly two ranks and silently wrong for any
# other number. A pre-spend review caught it before a paid four-GPU run: the arithmetic below gives -8.0 and
# 0.8 at world_size=4, and a hard-coded -4.0 would have marked a correct run as broken -- or, with the
# fail-open exit this file also had, a broken run as fine.
#
# Each rank gets y = 1 + 2*rank, so every rank's contribution is distinct. With y identical across ranks
# 1..n-1, a fault that swapped two of them would be invisible; here it is not.
def expected_mean_grad(world_size: int) -> float:
    """Mean of dL/dw = 2*(w*x - y)*x over the ranks, at w=0 and x=1."""
    return sum(-2.0 * (1 + 2 * rank) for rank in range(world_size)) / world_size


def expected_w_after_one_step(world_size: int, lr: float = 0.1) -> float:
    """One SGD step from w=0 against that averaged gradient."""
    return -lr * expected_mean_grad(world_size)

OUT_DIR = os.environ.get("DDP_OUT_DIR", "/evidence")
RUN_ID = os.environ.get("DDP_RUN_ID", "unset")
ATTEMPT = os.environ.get("DDP_ATTEMPT", "1")
STEPS = int(os.environ.get("DDP_STEPS", "3"))
NO_SYNC = os.environ.get("DDP_NO_SYNC", "") == "1"
# The step at which rank 1 kills itself, for the failure-contract run. 0 means never.
DIE_AT_STEP = int(os.environ.get("DDP_DIE_AT_STEP", "0"))
# Seconds to keep running after the last step, so this job holds its quota while another queues behind it.
#
# Three steps take about five seconds, which is why every run so far was admitted in the same second it was
# submitted: nothing was ever holding the GPU. Demonstrating that Kueue WITHHOLDS capacity needs a job that
# keeps it long enough for the wait to be observed.
HOLD_SECONDS = int(os.environ.get("DDP_HOLD_SECONDS", "0"))


def script_sha256() -> str:
    """The hash of this file, so a record says which code produced it.

    The image tag cannot say that. During local iteration this file is mounted over the copy baked into the
    image, so the same tag can carry two different programs; the hash is what distinguishes them.
    """
    with open(__file__, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


class Emitter:
    """One JSONL file per rank. Flushed per line, because a killed rank must not lose its last record."""

    def __init__(self, rank: int) -> None:
        os.makedirs(OUT_DIR, exist_ok=True)
        self.path = os.path.join(OUT_DIR, f"rank-{rank}.jsonl")
        self.handle = open(self.path, "a", buffering=1)
        self.rank = rank

    def emit(self, event: str, **fields: object) -> None:
        record = {
            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "run_id": RUN_ID,
            "attempt": ATTEMPT,
            "rank": self.rank,
            "event": event,
        }
        record.update(fields)
        line = json.dumps(record, sort_keys=True)
        self.handle.write(line + "\n")
        os.fsync(self.handle.fileno())
        # Also to stdout, because MLTrainingJob can attach a PersistentVolumeClaim and nothing else --
        # there is no field for a ConfigMap or an emptyDir. Sending the evidence to the log means the run
        # needs no volume at all and is collected with `kubectl logs`.
        #
        # ONE os.write, not print(). torchrun gives both ranks the same stdout, and print() can flush a line
        # in more than one write: the first cluster run came back with two JSON objects concatenated on one
        # line, which the collector could not parse. A single write of under PIPE_BUF (4096) bytes to a pipe
        # is atomic on Linux, so the ranks interleave between records instead of inside one.
        os.write(1, (line + "\n").encode())


def param_digest(model: nn.Module) -> str:
    """A hash over the parameters in a fixed order, to compare two ranks without shipping tensors around."""
    hasher = hashlib.sha256()
    for name, tensor in sorted(model.state_dict().items()):
        hasher.update(name.encode())
        # A uint8 view of the contiguous storage, not .numpy().tobytes().
        #
        # The image installs torch from the CPU index and nothing else, so numpy is absent and .numpy()
        # raises "Numpy is not available" -- after init_process_group had already succeeded, which made the
        # failure look like a rendezvous problem in the first run's truncated output.
        raw = tensor.detach().cpu().contiguous().flatten().view(torch.uint8).tolist()
        hasher.update(bytes(raw))
    return hasher.hexdigest()


def main() -> int:
    rank = int(os.environ["RANK"])
    world_size = int(os.environ["WORLD_SIZE"])
    emitter = Emitter(rank)

    # Deterministic and identical across ranks, so a difference between ranks is synchronisation and not seed.
    torch.manual_seed(0)
    torch.set_num_threads(1)

    dist.init_process_group(backend="gloo")
    emitter.emit(
        "rendezvous",
        world_size=world_size,
        backend=dist.get_backend(),
        pid=os.getpid(),
        hostname=socket.gethostname(),
        torch_version=torch.__version__,
        script_sha256=script_sha256(),
        no_sync=NO_SYNC,
        steps=STEPS,
        die_at_step=DIE_AT_STEP,
    )

    model = nn.Linear(1, 1, bias=False)
    # The starting point the arithmetic above assumes. Asserted rather than trusted to the initialiser.
    with torch.no_grad():
        model.weight.fill_(0.0)

    ddp = DDP(model)

    # Counters the comm hook fills in. Kept out of the hook's closure scope as a dict so the hook can mutate
    # them without a global.
    comm = {"calls": 0, "futures_completed": 0, "local_grads": []}

    def recording_hook(state, bucket):
        """Record the gradient BEFORE reduction, then do the real all-reduce and record its completion.

        Entering the hook proves only that DDP asked for a collective. What proves the collective HAPPENED is
        the future completing, so the two are counted separately and the write-up quotes the second.

        The bucket's buffer at entry holds this rank's own accumulated gradients -- that is what makes the
        pre-reduction value observable at all.
        """
        buffer = bucket.buffer()
        comm["calls"] += 1
        comm["local_grads"].append([float(v) for v in buffer.detach().clone().flatten()])

        if NO_SYNC:
            # The control. The hook returns the local gradient untouched, so no collective is issued and the
            # ranks must diverge. Its purpose is to show the check above can fail.
            future = torch.futures.Future()
            future.set_result(buffer)
            return future

        work = dist.all_reduce(buffer, op=dist.ReduceOp.SUM, async_op=True)

        def finish(fut):
            comm["futures_completed"] += 1
            return fut.value()[0] / world_size

        return work.get_future().then(finish)

    ddp.register_comm_hook(state=None, hook=recording_hook)

    optimiser = torch.optim.SGD(ddp.parameters(), lr=0.1)
    x = torch.tensor([[1.0]])
    # The whole point: the two ranks see different data, so an unsynchronised run cannot coincidentally agree.
    y = torch.tensor([[1.0 + 2.0 * rank]])

    for step in range(1, STEPS + 1):
        if DIE_AT_STEP and rank == 1 and step == DIE_AT_STEP:
            # A hard kill, not an exception: the contract under test is what the platform does when a rank
            # disappears without unwinding, which is how an OOM or a node eviction presents.
            emitter.emit("self_kill", step=step, signal="SIGKILL")
            os.kill(os.getpid(), 9)

        before = comm["futures_completed"]
        optimiser.zero_grad()
        loss = ((ddp(x) - y) ** 2).sum()
        loss.backward()

        local = comm["local_grads"][-1] if comm["local_grads"] else []
        reduced = [float(p.grad.flatten()[0]) for p in ddp.parameters()]
        optimiser.step()
        w = float(model.weight.flatten()[0])

        emitter.emit(
            "step",
            step=step,
            loss=float(loss),
            local_grad=local,
            grad_after_reduction=reduced,
            w_after_step=w,
            comm_calls=comm["calls"],
            futures_completed=comm["futures_completed"],
            futures_completed_this_step=comm["futures_completed"] - before,
            param_sha256=param_digest(model),
        )

    # The check, stated as a verdict the analysis does not have to re-derive.
    #
    # Only the first step has a hand-checkable expectation, because after it the ranks' losses depend on the
    # shared weight; later steps are covered by the cross-rank agreement below.
    # THIS run's first step, not the first step in the file.
    #
    # The record is appended, so a reused volume holds every earlier run's steps too -- and this loop
    # stopped at the first `step == 1` it met, which on a second attempt is the PREVIOUS run's. The
    # verdict would then be computed from numbers this process never produced, and it would usually
    # agree, because the earlier run computed the same expectation. Every record already carries the
    # run id and attempt; matching on them is what makes the read belong to this run.
    first = None
    with open(emitter.path) as handle:
        for line in handle:
            record = json.loads(line)
            if (
                record.get("event") == "step"
                and record.get("step") == 1
                and record.get("run_id") == RUN_ID
                and record.get("attempt") == ATTEMPT
            ):
                first = record
                break

    want_grad = expected_mean_grad(world_size)
    want_w = expected_w_after_one_step(world_size)
    verdict = {
        "world_size": world_size,
        "expected_mean_grad": want_grad,
        "expected_w_after_one_step": want_w,
        "tolerance": TOLERANCE,
    }
    if first is not None:
        got_grad = first["grad_after_reduction"][0]
        got_w = first["w_after_step"]
        verdict["observed_mean_grad"] = got_grad
        verdict["observed_w_after_one_step"] = got_w
        verdict["grad_matches"] = abs(got_grad - want_grad) < TOLERANCE
        verdict["w_matches"] = abs(got_w - want_w) < TOLERANCE

    # Cross-rank agreement, gathered rather than assumed. Counted apart from the gradient collectives above,
    # so the all-reduce tally in the write-up stays a statement about DDP's own traffic.
    #
    # A tensor collective, not all_gather_object: torch's object path pickles and then calls
    # `tensor.numpy().tobytes()` internally, so it raises "Numpy is not available" on this image exactly as
    # param_digest did. The digest is 32 bytes, which travels as uint8 without any of that.
    digest = param_digest(model)
    mine = torch.tensor(list(bytes.fromhex(digest)), dtype=torch.uint8)
    slots = [torch.zeros(32, dtype=torch.uint8) for _ in range(world_size)]
    dist.all_gather(slots, mine)
    gathered = [bytes(slot.tolist()).hex() for slot in slots]
    verdict["param_digests"] = gathered
    verdict["all_ranks_agree"] = len(set(gathered)) == 1

    # Fail closed. The checks above used to be computed, recorded, and then ignored.
    #
    # `return 0` regardless of the verdict is how a run that disproved its own hypothesis still reported
    # success: Job Complete, CR Succeeded, and a correctness failure visible only to whoever read the JSONL.
    # The control run (DDP_NO_SYNC=1) is expected to fail these checks, so it is exempted explicitly rather
    # than by leaving the gate open for everyone.
    checks = ("grad_matches", "w_matches", "all_ranks_agree")
    # A check that was never computed is not a check that passed.
    #
    # `is False` counted only recorded failures, so a run that produced no step at all -- DDP_STEPS=0,
    # or a step whose record never reached the verdict -- had an empty failure list and exited 0 on the
    # strength of initial parameters agreeing before any training happened. Missing is now a failure, and
    # it is named separately so the two are told apart in the record.
    missing = [name for name in checks if verdict.get(name) is None]
    failed = [name for name in checks if verdict.get(name) is False] + missing
    verdict["missing_checks"] = missing
    verdict["failed_checks"] = failed
    
    # The control run is exempted from the checks, not from having an expectation.
    #
    # `0 if (not failed or NO_SYNC)` passed the control run whatever it produced. Its whole purpose is to
    # show that switching synchronisation off makes the ranks diverge, so a control run in which they
    # AGREE has disproved the thing it exists to demonstrate -- and reported success. That is the same
    # shape as the defect the comment above describes, one level up: a result that cannot fail.
    #
    # So the control run has its own bar. It must diverge; missing the digest comparison entirely is a
    # run that measured nothing and fails too, rather than passing by absence.
    if NO_SYNC:
        agreed = verdict.get("all_ranks_agree")
        if missing:
            # The control is exempt from the arithmetic checks FAILING, not from having computed them.
            #
            # `missing` means a check was never evaluated -- no step ran, or the record never reached the
            # verdict. A control run that produced no arithmetic at all and then diverged would have passed
            # on the divergence alone, which is the same shape as the defect this gate was added to close.
            verdict["control_verdict"] = f"checks were never computed: {missing}"
            verdict["exit_code"] = 1
        elif agreed is None:
            verdict["control_verdict"] = "no rank comparison was recorded"
            verdict["exit_code"] = 1
        elif agreed:
            verdict["control_verdict"] = "the ranks agreed with synchronisation off, so this control shows nothing"
            verdict["exit_code"] = 1
        else:
            verdict["control_verdict"] = "the ranks diverged, as a run without synchronisation must"
            verdict["exit_code"] = 0
    else:
        verdict["exit_code"] = 0 if not failed else 1

    emitter.emit("verdict", **verdict)

    if HOLD_SECONDS > 0:
        # Held before tearing down the process group, so the Pod -- and therefore the quota reservation --
        # stays alive. Sleeping after destroy_process_group would keep the Pod too, but the run would no
        # longer be a training job holding capacity; it would be a sleeper wearing its name.
        emitter.emit("holding", seconds=HOLD_SECONDS)
        time.sleep(HOLD_SECONDS)

    dist.destroy_process_group()
    return int(verdict["exit_code"])


if __name__ == "__main__":
    sys.exit(main())
