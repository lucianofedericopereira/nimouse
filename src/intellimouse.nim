## Base IntelliMouse device type.
## Concrete subtypes (ProIntelliMouse, ClassicIntelliMouse) supply DeviceParams
## at construction time; all HID I/O lives here.

import std/os
import hidapi

type
  DeviceParams* = object
    vid*, pid*:           uint16
    iface*:               int
    usagePage*, usage*:   uint16
    writeReportId*:       uint8
    writeReportLen*:      int
    readReportId*:        uint8
    readReportLen*:       int

  IntelliMouse* = ref object of RootObj
    params*: DeviceParams
    hidDev*: ptr HidDevice
    path*:   string

# ── lifecycle ────────────────────────────────────────────────────────────────

proc open*(m: IntelliMouse) =
  m.hidDev = hidOpenPath(m.path.cstring)
  if m.hidDev == nil:
    raise newException(IOError,
      "cannot open device at \"" & m.path & "\": check permissions (udev rule / sudo)")

proc close*(m: IntelliMouse) =
  if m.hidDev != nil:
    hidClose(m.hidDev)
    m.hidDev = nil

template withDevice*(m: IntelliMouse, body: untyped) =
  ## Opens the device, executes body, then closes it even on error.
  m.open()
  try: body
  finally: m.close()

# ── HID enumeration helper ───────────────────────────────────────────────────

proc enumeratePaths*(p: DeviceParams): seq[string] =
  ## Returns the HID paths for all connected devices matching the given params.
  var info = hidEnumerate(p.vid.cushort, p.pid.cushort)
  let root = info
  while info != nil:
    if info.interface_number == p.iface.cint:
      # On Linux, usage_page/usage may both be 0 — fall through to interface match.
      let usageOk = (info.usage_page == 0 and info.usage == 0) or
                    (info.usage_page == p.usagePage.cushort and
                     info.usage      == p.usage.cushort)
      if usageOk:
        result.add($info.path)
    info = info.next
  hidFreeEnumeration(root)

# ── HID I/O primitives ───────────────────────────────────────────────────────

proc writeProperty*(m: IntelliMouse, prop: uint8, data: openArray[uint8]) =
  var buf = newSeq[uint8](m.params.writeReportLen)
  buf[0] = m.params.writeReportId
  buf[1] = prop
  buf[2] = uint8(data.len)
  for i, b in data: buf[3 + i] = b
  let written = hidSendFeatureReport(m.hidDev, addr buf[0], csize_t(buf.len))
  sleep(50)
  if written != m.params.writeReportLen:
    raise newException(IOError,
      "short write to device (" & $written & "/" & $m.params.writeReportLen & " bytes)" &
      " — device may be disconnected or permissions insufficient")

proc readProperty*(m: IntelliMouse, prop: uint8,
                   reqData: openArray[uint8] = []): seq[uint8] =
  ## Sends a read-request feature report and returns the payload from the response.
  ## `reqData` is optional extra bytes in the request (needed for button reads).
  var req = newSeq[uint8](m.params.writeReportLen)
  req[0] = m.params.writeReportId
  req[1] = prop
  req[2] = uint8(if reqData.len > 0: reqData.len else: 1)
  for i, b in reqData: req[3 + i] = b
  let sent = hidSendFeatureReport(m.hidDev, addr req[0], csize_t(req.len))
  if sent < 0:
    raise newException(IOError,
      "failed to send read request to device: check permissions (udev rule / sudo)")
  sleep(50)
  var resp = newSeq[uint8](m.params.readReportLen)
  # hidapi requires the report ID to be pre-filled in data[0] before
  # hid_get_input_report(); without it the call fails (returns -1) and resp
  # is left all-zero, which used to surface later as an IndexDefect on an
  # empty result seq rather than a clear error here.
  resp[0] = m.params.readReportId
  let got = hidGetInputReport(m.hidDev, addr resp[0], csize_t(resp.len))
  sleep(50)
  if got < 4:
    raise newException(IOError,
      "no response from device: check permissions (udev rule / sudo), " &
      "or the device may be disconnected")
  let dataLen = min(int(resp[3]), resp.len - 4)
  if dataLen == 0:
    raise newException(IOError,
      "device returned an empty response for property 0x" & $prop)
  result = resp[4 ..< 4 + dataLen]

# ── virtual interface ────────────────────────────────────────────────────────

method deviceName*(m: IntelliMouse): string {.base.} = "IntelliMouse"

method describe*(m: IntelliMouse): string {.base.} =
  ## Returns a human-readable description of the device's current settings.
  ## Device must be open when called.
  m.deviceName
