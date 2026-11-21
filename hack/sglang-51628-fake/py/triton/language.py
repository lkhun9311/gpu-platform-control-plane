"""triton.language, faked: the names a kernel's signature and body refer to."""


class constexpr:  # noqa: N801
    pass


def program_id(axis):
    return 0


def arange(a, b):
    return 0


def load(*a, **k):
    return 0


def store(*a, **k):
    return None
