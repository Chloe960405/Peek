# Peek

Peek is a small macOS menu bar app for checking Codex and Claude Code usage.

It reads usage from the local machine's existing Codex and Claude Code login state. It does not include or share any account credentials.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools
- Logged-in Codex account
- Logged-in Claude Code account

Install Xcode Command Line Tools if needed:

```bash
xcode-select --install
```

## Run From Source

Clone the repository:

```bash
git clone https://github.com/Chloe960405/Peek.git
cd Peek
```

Run the app:

```bash
swift run -c release Peek
```

The app will appear in the macOS menu bar.

## Build

```bash
swift build -c release
```

The compiled executable will be under `.build/`.

On Apple Silicon Macs, it is usually:

```bash
.build/arm64-apple-macosx/release/Peek
```

On Intel Macs, it may be:

```bash
.build/x86_64-apple-macosx/release/Peek
```

## Notes

- Peek uses the current user's local Codex and Claude Code credentials.
- If usage looks stale, quit and reopen Peek, then refresh.
- If Claude Code was reinstalled recently, make sure `claude` works in Terminal first:

```bash
claude --version
```
