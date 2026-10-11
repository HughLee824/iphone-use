# Adjust wheels from observed values

Read this only when operating a date/time or other picker wheel.

- Read the current selected value from the form or control and inspect the wheel's frame and child rows. Visible, enabled `text` is not a promise that tapping selects that value. If a value tap has no effect, prefer a controlled drag for similar wheels unless new evidence supports another interaction.
- `swipe oN:eN --direction up` moves the finger across 60% of the visible element height (width for horizontal movement). Slow velocity does not shorten that distance; this can cross several rows.
- Near the target, use explicit endpoints based on the observed row spacing: `swipe oN --from-x X --from-y Y --to-x X --to-y Y --velocity 100 --hold-duration 0.2`. These speed/hold values are starting points, not a one-row guarantee. Use the observation ID with endpoints; optionally add `--protect oN:eN` for an additional protected element.
- After each drag, read the actual value and adjust the remaining distance. Repeated no-change or overshoot calls for checking the selected field, frame, and interaction strategy before another attempt. Do not assume a minute-wheel wrap changes the hour or that changing the start preserves the intended end.
- A custom `scroll_view` is not a native `picker_wheel`. Do not invent a select-by-value CLI command. Use `iphone-use swipe --help` for supported parameters.
