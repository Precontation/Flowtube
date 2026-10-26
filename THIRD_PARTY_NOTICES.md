# Third-party notices

## Flow (FlowNeuro engine, Home feed assembly, InnerTube renderer parsers)

core/src/flow_neuro, core/src/home, core/src/api, core/src/models, core/resources and core/tests come from Flow Desktop, https://github.com/Flow-Tube/Flow-Desktop (commit 28bac82), by A-EDev and contributors, licensed GPL-3.0-only. Changes: SQLite/Tauri persistence replaced with in-memory snapshots (signals.rs, categories.rs, content_store.rs, co_watch.rs, language.rs, deep_flow.rs, home/channel_memory.rs, home/neighbours.rs; brain_store.rs and side_stores.rs removed), home/lanes.rs and home/inputs.rs adapted to the synchronous engine, locale fixed to English for InnerTube text.

## YTKACE (tools/macho_inject.py)

```
MIT License

Copyright (c) 2026 YTKACE contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Return YouTube Dislike (optional, built in CI)

When the workflow's *Return YouTube Dislike* option is on, the IPA also contains Return YouTube Dislike, https://github.com/PoomSmart/Return-YouTube-Dislikes, by PoomSmart and kirb, GPL-3.0. It is built unmodified from source by scripts/build-ryd.sh, using Logos's internal generator, YouTubeHeader and PSHeader (PoomSmart) and Theos's headers. scripts/ryd/libroot_stub.c stands in for libroot's path helper in the sideloaded app.
