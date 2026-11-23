import torch
import torch.nn.functional as F
from vllm.third_party.flash_linear_attention.ops.chunk import chunk_gated_delta_rule
torch.manual_seed(0)
T, H, HV, K, V = 75, 1, 2, 64, 64
q = F.normalize(torch.randn(1, T, H, K), dim=-1).half(); k = F.normalize(torch.randn(1, T, H, K), dim=-1).half()
v = torch.randn(1, T, HV, V).half(); g = F.logsigmoid(torch.randn(1, T, HV)); beta = torch.sigmoid(torch.randn(1, T, HV))
h0 = 0.5 * torch.randn(3, HV, V, K)
def run(cu, s):
    out = torch.full((v.numel(),), 1234.0, dtype=v.dtype)
    o, ht = chunk_gated_delta_rule(q, k, v, g, beta, initial_state=s.clone(), output_final_state=True, cu_seqlens=cu, core_attn_out=out)
    return o.clone(), ht.clone()
o, ht = run(torch.tensor([0, 5, 5, 75], dtype=torch.int32), h0)
o_ref, ht_ref = run(torch.tensor([0, 5, 75], dtype=torch.int32), h0[[0, 2]])
print("unwritten", (o[0] == 1234).all(-1).all(-1).sum().item(), "o_err", (o[0, 5:].float() - o_ref[0, 5:].float()).abs().max().item(),
      "state_err", (ht[2] - ht_ref[1]).abs().max().item(), "empty_keeps_h0", torch.equal(ht[1], h0[1]))
