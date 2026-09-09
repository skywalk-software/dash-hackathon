# Dash · GPT-6 Astra Hackathon SF

## One-sentence pitch

Built entirely with GPT-6 Astra and powered by Astra at runtime, Dash lets you speak and point inside a document while Astra works on your edits in parallel with your typing.

## Astra in development and in the product

The entire project was developed with GPT-6 Astra. That includes the earlier editor foundation and this isolated hackathon version.

- **GUI prototyping:** use Astra to create and iterate the native editor and interaction flows.
- **Prompt iteration:** work with Astra on complex reference-resolution, generation, and reconciliation prompts, targeting lower latency and higher accuracy.
- **Computer-use-assisted GUI testing:** use Astra to exercise the interface, inspect outcomes, and iterate on failures, reducing the amount of manual testing.

These describe the team’s development workflow. They are not a claim that this starter has completed a full end-to-end validation or that every latency/accuracy goal has been measured.

Astra also powers all three runtime reasoning stages: interpretation, generation, and reconciliation. It understands complex user intent across speech, pointing, and text selection, then generates and refines text while accounting for a changing document. Supporting speech recognition supplies a transcript and word times; Astra receives them with timestamped interaction events and document context. Raw audio/screen pixels are not sent to Astra by this client.

Computer use belongs to the development/testing story. It is separate from the runtime editor’s use of Astra for interpreting intent and producing text changes.

The development claim describes the model used to create the project. The contribution boundaries below separately describe inherited code versus work added in this version; do not imply all inherited work happened during the event.

## One-minute demo outline

| Time | Show |
|---|---|
| 0–10 s | Open a short sample document: “We built and GUI-tested this with Astra; Astra also understands the speech and pointing inside it.” |
| 10–25 s | Record: “Make this paragraph shorter. Turn these details into a list.” Select each passage while speaking. |
| 25–40 s | Stop recording and change a date manually while Astra’s proposals are pending. |
| 40–55 s | Inspect the resulting edits and whether the new date was preserved. Show a visible conflict if one occurred. |
| 55–60 s | Close on the dual role: Astra helped iterate the GUI and prompts, and powers the app’s intent → generation → reconciliation loop. |

This is an intended demo sequence, not a completed test result. Rehearse with actual model output before recording. Do not present a scripted or mocked result as a live Astra result.

## What is inherited, and what this version changes

**Existing foundation:** the native text editor, cursor/capture contract, scoped interpretation/generation/reconciliation prompts, Automerge state, scheduler, and change-inspection UI came from an earlier editor prototype.

**This isolated version:** normal system-microphone capture; a configurable speech/timing adapter; removed private SDK/infrastructure; a dedicated GPT-6 Astra Responses API client across all editing stages; new branding, setup documentation, and publication checks.

A fresh Git history does not mean every line was written during the event. For submission, identify exactly which changes your team made within the hackathon window and demonstrate those changes. Use actual diffs, runs, and development records to show how the team worked with Astra.

## Astra capabilities: current versus planned

Implemented: contextual interpretation, structured outputs, concurrent generation requests, and semantic reconciliation against the latest document. The application owns job scheduling and revision validation.

Planned: Astra async tool calling and WebSocket mid-turn steering. Those API capabilities are not used by the current client and should not be claimed in a demo.

## Before submitting

Confirm event rules, repository visibility, model access, and demo-link access. The supplied participant guide requires a public repository and an accessible one-minute demo that distinguishes work created during the event. Changing repository visibility and submitting the entry are separate release actions.

This repository does not redistribute the participant guide, event credentials, access links, or private event material.
