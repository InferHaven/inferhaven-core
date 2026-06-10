# Licensing

## Why FSL-1.1-Apache-2.0?

InferHaven Core uses the [Functional Source License 1.1 with Apache 2.0 Future License](https://fsl.software/). This page explains what that means for you and why we chose this license.

In short: FSL lets you do almost anything with InferHaven Core *except* turn it into a managed hosting service that competes directly with InferHaven Cloud. Two years after each version's release, even that restriction lifts and the version becomes Apache 2.0 — fully permissive, no strings.

## What You Can Do

You can use, modify, run, redistribute, and integrate InferHaven Core for:

- **Personal use.** Run it on your laptop, your home server, your homelab GPU rig.
- **Internal company use.** Deploy it on your company's infrastructure for your own engineers to use, at any scale. No seat counts, no usage reporting, no phoning home.
- **Modification and forking.** Patch it, fork it, change the defaults, swap out components, build on top of it.
- **Commercial software products** that include or depend on InferHaven Core, as long as those products are not themselves a competing managed-hosting offering.
- **Consulting and professional services** — setting up InferHaven Core for clients, customizing it, training their teams, supporting it under contract.
- **Research and education**, commercial or not.

If your use case sounds like "I want to run this for myself, my team, my company, or my customer," it's allowed.

## What You Cannot Do (For Two Years)

You cannot offer a commercial product or service whose value proposition substantially overlaps with **InferHaven Cloud** — our managed offering of the same underlying technology — until the version of Core you're using ages out of its two-year FSL window.

Concretely, that means you cannot:

- Spin up a public service called "Managed InferHaven" (or similar) and sell hosted InferHaven instances on your infrastructure to third parties.
- Take Core, slap a billing system on it, and resell it as a hosted product that competes head-on with InferHaven Cloud.

Note that this restriction is about **competing managed hosting**, not about whether you charge money in general. Selling a hardware appliance that runs Core, charging for consulting hours, or building a separate product that *uses* Core internally are all fine.

## Why Not MIT or Apache 2.0 from the Start?

We considered it. The honest answer is: we want Core to become a real, well-maintained, community-shaped project, and the only way to make that sustainable is to protect the business model that funds the maintainers.

InferHaven Cloud is what pays for the people who write Core. If a hyperscaler or a well-funded competitor could legally take Core on day one, wrap it in a managed-hosting product, and out-market us, the maintenance funding goes away — and so does Core, eventually. FSL buys us a two-year head start on each version. That's enough time to keep the lights on and stay ahead.

This is the same reasoning behind Sentry's adoption of FSL for their own project. We think it's a reasonable trade: you get all the practical freedoms of an open-source license, and we get to keep building Core.

## Why Not AGPL?

AGPL was our placeholder license, and we moved off it deliberately.

AGPL's network-use provision creates real friction for enterprise self-hosters — the exact audience we *want* to support. Companies with mature legal review processes often have blanket policies against AGPL, even for internal-only deployments, because the copyleft scope is broad and the risk surface is hard to assess. We don't want a legal-review tax to be the reason someone gives up on running InferHaven Core internally.

FSL is much narrower: it restricts one specific kind of commercial use (competing managed hosting) and leaves everything else — including internal commercial use, integration, and modification — fully permitted.

## What "Competing Use" Actually Means

The license text defines a Competing Use as making the Software available to others in a commercial product or service that substitutes for InferHaven Core, substitutes for InferHaven Cloud, or offers substantially similar functionality.

A few worked examples:

| Scenario | Competing use? |
| --- | --- |
| Your engineering team uses Core to host shared coding models on the company GPU cluster. | **No** — internal use is explicitly permitted. |
| You run Core on a VPS to power your personal coding setup. | **No** — personal use. |
| You sell a turnkey "AI workstation" appliance with Core preinstalled. | **No** — selling hardware that happens to run Core is fine. |
| You charge a client to set up Core on their infrastructure and train their team. | **No** — professional services are explicitly permitted. |
| You stand up `managedinferhaven.com` and rent hosted InferHaven instances to anyone with a credit card. | **Yes** — this is the exact use case the license restricts. |
| You build a SaaS product that uses Core internally for inference but exposes a completely different product to your users. | **Probably no**, unless that product's value proposition substantially overlaps with InferHaven Cloud's. If you're unsure, ask. |

If you're not sure whether your use case is permitted, [open a Discussion](https://github.com/InferHaven/inferhaven-core/discussions) — we'd rather give you a clear answer up front than have you build something on shaky ground.

## The Two-Year Rollover

This is the most important feature of FSL and the reason we picked it over a permanent source-available license.

Every version of InferHaven Core that we release is licensed under FSL-1.1 for **exactly two years from its release date**. After that two-year window expires, that version automatically — by the terms of the license itself, no further action required — converts to the Apache License 2.0. Apache 2.0 has no field-of-use restrictions: at that point, anyone can do anything with that old version, including run a competing managed-hosting service on top of it.

Practically, this means:

- The cutting-edge version of Core is always FSL.
- Versions older than two years are always Apache 2.0.
- The community always has a permissively-licensed version of Core available — just not the newest one.

This is the "we eventually give it all away" property. We get a two-year commercial head start on each release; you get a guarantee that no version of Core stays locked up forever.

## Questions

Open a [Discussion](https://github.com/InferHaven/inferhaven-core/discussions) on GitHub if anything here is unclear, or if your use case doesn't fit cleanly into the examples above. We're happy to give you a straight answer.
