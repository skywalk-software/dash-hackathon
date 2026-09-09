# Next Astra experiments

- [ ] Validate a real microphone → transcript → Astra → edit demo.
- [ ] Explore Astra async tool calling to dispatch proposals as they become ready.
- [ ] Explore WebSocket mid-turn steering for spoken corrections while Astra is working.
- [ ] Compare Astra reasoning effort on ambiguous selections and conflicting revisions.
- [ ] Show why Astra chose a particular passage in the task inspector.
- [ ] Add a small, synthetic interaction suite for reference-resolution quality.

These are planned experiments. Current concurrency uses independent Responses API calls coordinated by the local scheduler.

## Prototype polish

- [ ] Add API/speech settings in the app.
- [ ] Add a microphone selector and recording-duration indicator.
- [ ] Calibrate microphone latency against cursor events.
- [ ] Add “delete recordings” and package/sign the Node helper.

Keep changes small and demoable. Record what was actually validated.
