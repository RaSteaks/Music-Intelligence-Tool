"""Load only the required vector algorithms from the pinned native binding.

essentia.standard instantiates every registered algorithm to build classes and
docstrings on import (about 27 s on the evaluation Mac). Its standard.py uses
Algorithm, convertData, __configure__ and __compute__. This narrow adapter
follows that binding for single-vector audio algorithms, with an exact version
pin so incompatible changes fail rather than silently changing behavior.
"""
from importlib.metadata import version


def vector_algorithm(name, **parameters):
    import numpy as np
    from essentia import _essentia
    from essentia.common import convertData

    if version("essentia") != "2.1b6.dev1389":
        raise RuntimeError("旋律运行环境版本不匹配，请运行 ./script/setup.sh music。")
    algorithm = _essentia.Algorithm(name)
    algorithm.__configure__(**{key: convertData(value, algorithm.paramType(key)) for key, value in parameters.items()})

    def compute(signal):
        return algorithm.__compute__(np.ascontiguousarray(signal, dtype=np.float32))
    return compute
