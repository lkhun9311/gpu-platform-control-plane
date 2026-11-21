"""triton.knobs, faked: compilation.listener is a plain attribute, absent when FAKE_NO_LISTENER=1."""

import os


class _Compilation:
    listener = None


class _NoListener:
    pass


compilation = _NoListener() if os.environ.get("FAKE_NO_LISTENER") == "1" else _Compilation()
