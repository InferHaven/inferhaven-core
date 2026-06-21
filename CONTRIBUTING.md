# Contributing to InferHaven Core

First, thank you for considering a contribution. InferHaven Core's source is fully available (we license it under FSL-1.1, a fair source license) because we believe private AI coding should be a right, not a feature gate, and the project is stronger when the community has a real role in shaping it.

This document explains how to contribute in a way that's productive for everyone, including how to set expectations around scope, response times, and what kinds of contributions we're looking for.

## A Note on Project Scope

InferHaven Core is **opinionated infrastructure**. It is not trying to be a kitchen-sink AI platform. It is designed to do one thing well: provide a plug-and-play, self-hostable stack for running private AI coding assistants with optional GPU acceleration in a secure development environment.

This means that not every well-intentioned feature request or PR will be accepted, even if the code is good. We aim to keep Core focused, maintainable, and easy to understand. If you have a feature idea, **please open a GitHub Discussion or Issue before writing code**. This saves you time and helps us have a real conversation about whether the change fits the project's direction.

## Maintainer Bandwidth

InferHaven Core is currently maintained by a small team (initially one person). We will do our best to respond to issues, discussions, and PRs in a reasonable timeframe, but please expect:

- **Issues and Discussions**: typically a response within 1-2 weeks
- **Pull Requests**: typically a first review within 2-4 weeks, sometimes longer
- **Security reports**: response within 72 hours (for now please email [lookout@inferhaven.com](mailto:lookout@inferhaven.com))

If you don't hear back, a polite ping after the timeframe above is welcome and appreciated.

## How to Contribute

There are many ways to contribute that don't involve writing code, and all of them are genuinely valuable:

### 🐛 Report a Bug

Open a GitHub Issue with:

- What you expected to happen
- What actually happened
- Steps to reproduce
- Your environment (OS, Docker version, GPU model if relevant)
- Logs or screenshots if applicable

A clear bug report is one of the most useful contributions to the project.

### 💡 Suggest a Feature or Improvement

**Please open a Discussion, not a PR.** Discussions are a much better place to explore ideas, get feedback, and build consensus. If a Discussion leads to "yes, let's do this," we'll convert it to an Issue and you (or someone else) can pick it up.

We're especially open to:

- Performance improvements
- Better model support (new open-source coding models, better quantization configs)
- Improved documentation and self-hosting guides
- Better defaults for common setups
- Bug fixes

We're cautious about:

- Major architectural changes
- New integrations that significantly expand the surface area
- Anything unrelated to actual AI inferencing backends or usage

### 📝 Improve Documentation

Documentation PRs are almost always welcome and tend to be reviewed faster than code PRs. Typos, clarifications, better examples, and additional self-hosting guides are all great contributions.

### 💬 Help Other Users

Answering questions in GitHub Discussions or the [InferHaven Discord](https://discord.gg/X5htGNnEh5) is hugely valuable and doesn't require any code changes.

### 🧪 Submit a Pull Request

For code contributions, please follow this flow:

1. **For anything beyond a small bug fix or typo**: open an Issue or Discussion first. This is the single most important step. Surprise PRs for new features will often be closed with a request to discuss first, not because we don't appreciate the effort, but because we want to avoid wasting your time on something we won't merge.
2. **Fork the repo and create a feature branch** off `main`.
3. **Make your changes** following the code style of the existing codebase.
4. **Test your changes** locally. For changes affecting the Docker Compose stack, verify that `docker compose up` produces a working environment.
5. **Sign the CLA** (see "Contributor License Agreement" below). This is automated via CLA Assistant when you open a PR.
6. **Open a PR** with a clear description of what changed and why. Link to the Issue or Discussion that prompted the change.
7. **Be patient and responsive during review.** We may ask for changes, suggest alternative approaches, or request that the change be scoped down.

## AI-assisted contributions

AI assistants are welcome here. We use them to draft code, refactor, generate tests, and write docs. The bar is the same no matter how a change is produced: you understand it, you test it, and a human reviews every change before it merges. AI accelerates the work; it doesn't replace human judgment or ownership.

## Pull Request Criteria

PRs are more likely to be merged quickly if they:

- Are scoped to a single change (one feature or one bug fix, not several)
- Include or update relevant documentation
- Don't introduce new external dependencies without discussion
- Follow the existing code style and conventions
- Have a clear commit history (we may ask you to squash or rebase before merge)
- Were discussed in an Issue or Discussion first (for non-trivial changes)

PRs are likely to be **closed without merge** if they:

- Add major features without prior discussion
- Significantly expand the project's scope (e.g., adding support for non-coding AI use cases)
- Conflict with the project's direction (e.g., adding telemetry, adding features that duplicate InferHaven Cloud functionality)
- Introduce significant maintenance burden without clear benefit
- Have been inactive for 30+ days without response to review feedback

We will always try to explain *why* a PR is closed. Closing a PR is not a judgment on the contributor. It's a project-fit decision.

## Contributor License Agreement (CLA)

Before we can accept your code contribution, you'll need to sign our Contributor License Agreement (CLA). This is automated through [CLA Assistant](https://cla-assistant.io/). When you open your first PR, a bot will guide you through signing it.

**Why a CLA?** The CLA gives InferHaven LLC the rights needed to relicense Core in the future if needed (for example, to offer commercial licenses to enterprises that need to escape FSL terms, or to adjust the license as the project matures). Without a CLA, we'd need to track down every contributor to make any license change.

**What the CLA does NOT do**: It does not transfer ownership of your contribution. You retain copyright in what you wrote. It grants InferHaven a broad license to use, modify, sublicense, and relicense your contribution.

If you can't or don't want to sign the CLA, you can still contribute in many other ways: filing bugs, writing documentation, helping users in Discussions, and so on.

## Development Setup

See [docs/development/](./docs/development/) for the development guide: local dev loop, repository layout, how to add a new coding-assistant harness, and how to run the linters and smoke tests.

## Code of Conduct

InferHaven follows a simple principle: **be kind, be patient, and assume good faith.** Disagreement is fine; disrespect is not. Participation in the project is governed by our [Code of Conduct](./CODE_OF_CONDUCT.md) (the Contributor Covenant); violations can result in removal from the project. Report concerns to [lighthouse@inferhaven.com](mailto:lighthouse@inferhaven.com).

## License of Contributions

By contributing to InferHaven Core, you agree that your contributions will be licensed under the same Functional Source License 1.1 with Apache 2.0 Future License (FSL-1.1-Apache-2.0) as the rest of the project. See the [LICENSE](./LICENSE) file for full terms.

## Questions?

Open a Discussion on GitHub, or [reach out to us](mailto:lighthouse@inferhaven.com). We're happy to help.

Thanks again for being here.

— The InferHaven Team
