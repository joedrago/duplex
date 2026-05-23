# Agent guidelines

## Formatting & linting

After any change in this repo, before considering the task done:

- **Rust:** must pass `cargo fmt` and `cargo clippy`.
- **JavaScript:** must pass `npm run format` (Prettier) and `npm run lint` (ESLint).

Always invoke the project-wide commands — `cargo fmt`, `cargo clippy`, `npm run format`, `npm run lint` — and let them walk the entire repo. Never run the underlying tools (`prettier`, `eslint`, `rustfmt`, etc.) directly on individual files or subdirectories. The npm-script wrappers exist so one permission grant covers every invocation; bypassing them forces a fresh approval every time.
