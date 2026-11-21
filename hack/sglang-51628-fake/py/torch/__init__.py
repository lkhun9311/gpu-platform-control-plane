"""A fake torch: only what probe_hook.py and measure.sh's version line touch."""

__version__ = "0.0-fake"


class version:  # noqa: N801
    cuda = "13.0"


class _Tensor:
    def __init__(self, n):
        self.n = n

    def sum(self):
        return float(self.n)


def zeros(n, device=None):
    return _Tensor(n)


class cuda:  # noqa: N801
    @staticmethod
    def synchronize():
        pass

    @staticmethod
    def get_device_name(i=0):
        return "NVIDIA A10G"
