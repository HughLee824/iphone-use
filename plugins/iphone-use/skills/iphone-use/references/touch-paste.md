# Touch paste in standard and runner modes

Use only when `result.support.textMethods` includes `touch-paste`. This is an explicit alternative to keyboard typing, useful when an app closes its editor on keyboard changes. It does not switch control backends, call XCTest typing, prepare/register a keyboard or send a Paste shortcut. The host uses only the Apple clipboard service; subsequent UI gestures use the selected mode.

This guarantee applies to the input path. Runner session startup can independently trigger XCTest keyboard registration; this method does not alter startup.

1. Inspect a current screenshot and open the intended input if needed. Do not call text-prepare for this method.
2. Run `type oN --mode insert --method touch-paste --text TEXT --observe` (or `--stdin`). Both modes require a screenshot reference. Nonempty literal text up to 4096 UTF-8 bytes, including LF/CR/CRLF, is supported. No replace/append or field/caret/ignore rectangles.
3. Read the returned image. `outcome=prepared`, `phase=awaiting_touch_paste`, `textInserted=false` mean only the clipboard is ready. Preserve `action.result.pasteboard.transactionID`. If capture fails, observe; do not stage again. If the reply is lost, inspect status.touchPaste and the screen before deciding what happened.
4. Long-press the actual input with the latest observation and `--observe`; inspect the menu. Tap its visible Paste/粘贴 with fresh coordinates and `--observe`. Never hard-code a menu position, guess an unseen menu, or substitute Command-V. Focus and selection are determined by the actual UI.
5. Verify complete text and placement, preservation of existing content and no unintended submission. Unknown touch receipts require visual inspection, not replay. If the menu is unavailable or input remains uncertain, stop and disconnect for clipboard cleanup.
6. Only after seeing the expected result, call `text-finish oN --transaction ID`. This records caller verification and restores the original clipboard; it does not verify text itself. Runner completion need not attach a new image; use the existing current observation unless another action invalidates it.

Use --agent-output when supported. Pending transactions block another type/press/text-prepare and app open/terminate/relaunch; finish or disconnect first. Status reports the pending transaction without clipboard contents. Each tap/double-tap/long-press also checks that the staged clipboard still belongs to this session. If another client changed it, do not overwrite it or automatically stage/paste again.

Original clipboard bytes remain in host memory and are restored only while ownership matches. Disconnect/idle cleanup releases the service and reports `cleanup.touchPaste`; unknown restoration is never retried automatically. Keep the host alive until verification/cleanup. Forced termination cannot guarantee restoration. A successful preparation or restoration is not proof the app accepted text.
