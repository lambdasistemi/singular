import RejectedFoldGate
set_option autoImplicit false
open Singular RejectedFold RejectedFoldGate
namespace RootRepair
/-- info: (true, true, true, true) -/
#guard_msgs in
#eval (resAR.isOk, resMX.isOk, resZN.isOk, resCT.isOk)
/-- info: (true, true, true) -/
#guard_msgs in
#eval (decide (fund7.inputLovelace >= tip500), decide (fund8.inputLovelace >= tip500),
       decide (fund9.inputLovelace >= tip500))
-- The same evOk cannot override an underfunded selected request.
/-- info: "request-underfunded" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk ctxMain 0 0 0
  { cOut with funding := [{ fund8 with inputLovelace := 0 }, fund7] }
  [i8] [.rejected] [] [])
-- Inverted and empty half-open intervals refuse at the batch boundary.
/-- info: ("invalid-range", "invalid-range") -/
#guard_msgs in
#eval (errOf (candFold tip500 e17Consumer evOk ctxBad 0 0 500 cOut
  [i8] [.rejected] [] [refund8]),
  errOf (candFold tip500 e17Consumer evOk
    { ctxMain with rangeUpper := some 5000 } 0 0 500 cOut
    [i8] [.rejected] [] [refund8]))
-- Moving the one window changes both observations consistently;
-- older submitted request can no longer claim late rejection.
/-- info: "reject-timing" -/
#guard_msgs in
#eval errOf (candFold tip500 e17Consumer evOk
  { ctxMain with rangeLower := 1000, rangeUpper := some 2000 }
  0 0 500 cOut [i8] [.rejected] [] [refund8])
end RootRepair
