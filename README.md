# Topnotchers

A minimal notch monitor for Claude Code and Codex on macOS.

![Topnotchers demo](docs/demo.gif)

The island uses the notch's own black and shape, so it reads as part of the hardware, and with no
agent running there is nothing on screen. Each session adds a small pixel pet beside the notch. It
animates while the agent works, gets an orange dot when it asks you something and a green one when
it's done. Hover a side and its pets fan out, one per session; the one under the pointer says what
it was asked and what it is doing right now. With more than three they ride a strip that scrolls as
you sweep across it.

Questions and permission prompts drop down under the notch, so you can answer without finding the
terminal. Clicking a pet focuses its Ghostty tab, or opens the thread in ChatGPT for Codex sessions
started there.

It's native AppKit: about 42 MB of memory at peak, no measurable CPU when nothing is happening, no
Dock icon, no account and no network access.

## Install

```sh
brew install joey-david/tap/topnotchers && topnotchers-setup
```

or `curl -fsSL https://raw.githubusercontent.com/joey-david/topnotchers/master/install.sh | bash`.
Needs Apple silicon, macOS 14+ and the Xcode Command Line Tools.

---

Made by Joey ([@t0rt0ised](https://x.com/t0rt0ised)).

Apache 2.0 licensed. If you ship something built from it, keep the [NOTICE](NOTICE) file with it.
