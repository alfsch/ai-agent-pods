## What and why

## Checklist
- [ ] `tests/check.sh` passes (syntax, ShellCheck, stub tests with all mutants killed)
- [ ] Each fix has a test that fails without it, and a mutant for the changed line
- [ ] `tests/integration.sh` run, if the sidecar, the image or the installer changed
- [ ] README and docs updated, if an option, a path or a default changed
- [ ] Still runs under macOS Bash 3.2
