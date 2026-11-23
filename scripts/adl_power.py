"""Read the AMD GPU's own sensors (power, activity, clocks, temperature) through the
driver's ADL library (atiadlxx.dll), so GPU power can be measured with no extra hardware.

  sensors = AdlSensors(); sensors.read() -> {sensor_index: value}
Sensor numbers follow ADL's ADLSensorType (adl_defines.h); NAMES lists the ones used here.
"""
import ctypes as C

NAMES = {1: "GFX clock (MHz)", 2: "memory clock (MHz)", 8: "edge temperature (C)",
         19: "GFX activity (%)", 20: "memory activity (%)", 21: "GFX voltage (mV)",
         23: "ASIC power (W)", 27: "hotspot temperature (C)"}

_MALLOC = C.CFUNCTYPE(C.c_void_p, C.c_int)


class _Sensor(C.Structure):
    _fields_ = [("supported", C.c_int), ("value", C.c_int)]


class _PMLog(C.Structure):
    _fields_ = [("size", C.c_int), ("sensors", _Sensor * 256)]


class AdlSensors:
    def __init__(self, adapter=None):
        self.dll = C.CDLL("atiadlxx.dll")
        self._malloc = _MALLOC(lambda n: C.cast(C.create_string_buffer(n), C.c_void_p).value)
        self._keep = []
        def malloc(n):
            b = C.create_string_buffer(n)
            self._keep.append(b)
            return C.addressof(b)
        self._malloc = _MALLOC(malloc)
        self.ctx = C.c_void_p()
        if self.dll.ADL2_Main_Control_Create(self._malloc, 1, C.byref(self.ctx)) != 0:
            raise RuntimeError("ADL2_Main_Control_Create failed")
        n = C.c_int()
        self.dll.ADL2_Adapter_NumberOfAdapters_Get(self.ctx, C.byref(n))
        self.adapter = adapter
        if adapter is None:                       # first adapter index that returns PMLog data
            for i in range(n.value):
                if self._query(i) is not None:
                    self.adapter = i
                    break
        if self.adapter is None:
            raise RuntimeError("no ADL adapter returns sensor data")

    def _query(self, idx):
        out = _PMLog()
        out.size = C.sizeof(_PMLog)
        if self.dll.ADL2_New_QueryPMLogData_Get(self.ctx, idx, C.byref(out)) != 0:
            return None
        vals = {i: out.sensors[i].value for i in range(256) if out.sensors[i].supported}
        return vals or None

    def read(self):
        return self._query(self.adapter)
