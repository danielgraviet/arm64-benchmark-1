# How Daniel likes to write (briefs, diligence, customer-facing docs)

Use this for Daytona compute briefs, partner notes, and similar essays. The Qualcomm sandbox brief in `docs/qualcomm-sandbox-compute-brief.md` is the reference draft. Prefer that voice over earlier agent drafts.

## Job of the document

- One clear ask from the reader’s boss, not a kitchen-sink report. For the Qualcomm note that was: performance outcomes, key learning, what we expect of future chips, and why agent/AI CPU work is different.
- Short. Aim for a few pages. Cut tables, graphs, appendices, and “source dumps” unless someone asked for them.
- The reader is not stupid. Do not title sections “how we can work together” as a pep talk, then write slogans. If collaboration belongs, write the actual technical exchange (what traces we can run, what counters we want, what questions we would ask).
- Do not write like you googled the other company’s Investor Day. No spec sheets, ship dates, Meta deals, perf/watt claims, or SKU catalogs. Enthusiasm without Wikipedia.
- Do not name their unreleased chip to flatter them. Describe the bar so they conclude they should put hardware in front of us.

## Structure

Lead with what Daytona actually runs, then one concrete result, then why the workload is different, then what future silicon has to do.

A good spine looks like:

1. Environment vs accelerator (CPU is on the critical path).
2. What we learned from a named chip, then the others as tradeoffs.
3. Why agent work stresses CPUs differently.
4. What that implies for future chips.
5. Partnership only if it is specific (workloads we can run, questions we cannot answer alone, what we would test next).

Do not open with “no single ISA wins everything.” Everyone knows that. Name the chips and say what each did.

## Voice

- Direct, complete sentences. Short paragraphs. One idea per paragraph.
- We/our. Concrete nouns (sandbox, pytest, tenancy, worker-hours). No consultant filler: “scoreboard,” “vocabulary gap,” “spine of our compute requirements,” “workload truth plus eval capacity.”
- Bold a small number of claims, not whole paragraphs.
- Questions as numbered lists when they are the point of the section.
- Keep one or two headline numbers in prose (e.g. 7s vs 17s). Do not paste comparison matrices people will skim.
- Simple lines for requirements. Bad: “we have learned that performant CPUs for us need burst single-thread speed on mixed Python…” Good: “A good CPU for this work is fast on one mixed burst, still fast when the node is packed, and not why the accelerator is waiting.” Then unpack later.

## Do not use

- Em dashes or semicolons.
- Graphs unless asked.
- Exact-number tables for partner/investor skims.
- Fake-humble hedges that are really a data dump (“those figures are Qualcomm’s, not Daytona’s”).
- Teaching-the-reader titles that insult them, unless the section underneath is adult and specific (the Qualcomm draft’s collaboration sections are the latter).
- Internal junk: harness flags, NumPy probes that are not customer work, Firecracker/NUMA laundry lists, reproduce commands, appendix provenance.

## Tradeoffs, not winners

Explain each platform: what it won, where it fell over, why that matters for production tenancy. Contrast ARM64 platforms with each other. Keep x86 media/vector as a real tradeoff, not a footnote. Peak core speed and packed-node behavior are equal first-class metrics.

## Partnership tone

If the audience is an investor or silicon team: we bring production-shaped agent load and density curves. They bring counters, topology, and what actually saturates. End on the evaluation bar and what we want to test next, not a five-step joint-product playbook.
