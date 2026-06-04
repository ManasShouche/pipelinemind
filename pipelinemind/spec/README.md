# PipelineMind — Spec Folder

Two focused specifications for PipelineMind. Read in the order that
matches your role.

| File                                         | For                                            | Read first if you want to know …                          |
|----------------------------------------------|------------------------------------------------|-----------------------------------------------------------|
| [`FUNCTIONAL_SPEC.md`](./FUNCTIONAL_SPEC.md) | Product, mentors, reviewers, end users         | **What** the system does and **why** it matters.          |
| [`TECHNICAL_SPEC.md`](./TECHNICAL_SPEC.md)   | Engineers extending, deploying, or debugging   | **How** the system is built and how to change it safely.  |

## How the spec folder relates to the rest of the docs

- `spec/FUNCTIONAL_SPEC.md` — declarative requirements. Stable.
- `spec/TECHNICAL_SPEC.md` — declarative design. Stable.
- `docs/INTERNALS.md` — narrative deep-dive of how the running code
  works module-by-module. Reflects current implementation; may shift.
- `docs/CHANGES_DETAILED.md` — engineering record of *what changed*
  and *why* over time.
- `docs/CHANGELOG.md` — terse, user-facing version notes.
- `docs/ARCHITECTURE.md` / `docs/API_REFERENCE.md` /
  `docs/SETUP.md` / `docs/HANDOVER.md` — operator-facing guides.

Use the **spec** to argue about *requirements*; use the **docs** to
understand *what the code does today*.
