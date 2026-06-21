# Codebase relevance ranks and informs; it never hides a tool or gates detection

The Bootstrap censuses the project (cheap and deterministic, driven off `git ls-files`)
and reports, for **every** tool, how relevant it is to *this* codebase together with the
evidence behind the verdict — "0 tabular files → DuckDB low relevance here", "1,240
`.java` → ast-grep high". This is the install-time projection of the repo's standing rule
— *a non-standard tool must beat the standard tool for THIS task; novelty is never the
reason.* Relevance is used to **rank** which Missing tools to recommend and to flag
Available-but-unneeded ones honestly — but it **never hides** a tool from the report and
**never gates** detection. Showing only "relevant" tools would be the opposite of the
transparency the requirement asks for, and would conflict with the zero-deny stance.

## Considered Options

- **Hide/skip irrelevant tools** — rejected: less honest, and it invites a future
  "tidy-up" that suppresses low-relevance tools. The deliberate no is the point of this ADR.
- **Inform-only, no ranking** — rejected: the requirement is to make clear *which* tools
  would be useful here, which is a ranking, not a flat list.
- **Gate detection to relevant tools** — rejected: detection stays complete and
  deterministic; relevance is a layer on top of a full inventory, not a filter before it.

## Consequences

- Relevance is a project fact → it lives in the project inventory JSON (ADR-0001) and is
  regenerated on re-detect, staying in sync as the codebase evolves.
- A **global** Bootstrap has no codebase: it says so and gives generic recommendations,
  pointing the user to run a project Bootstrap for codebase-specific advice. This matches
  the project/global asymmetry the requirement emphasizes.
- The census must be cheap + deterministic: driven off `git ls-files`, bucketed counts,
  sorted output — no full-tree walk on a large repo.
- New testing seam: `census(repo) → counts` and `rank(census, inventory) → verdicts` are
  pure functions verified with repo fixtures (extends the seam set in the PRD).
