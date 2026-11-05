# Third-party notices

Poinky is MIT licensed (see [LICENSE](LICENSE)). It includes or downloads the following.

## Included in this repository

| Component | Where | License |
|---|---|---|
| [three.js](https://threejs.org) r160 | `vendor/three.min.js` | MIT, © 2010-2023 three.js authors |

## Downloaded by the installer (not stored in this repository)

The natural voice is installed on your Mac by `phonon/install.sh`. Poinky only talks to it through a local helper process.

| Component | Source | License |
|---|---|---|
| [Phonon 31m](https://huggingface.co/gradium/phonon-31m-en) model (weights, tokenizer, default voice) by Gradium | Hugging Face, `gradium/phonon-31m-en` | Apache-2.0 |
| Voices from the [Phonon voice catalog](https://huggingface.co/gradium/phonon-voices) (25 English voices) | Hugging Face, `gradium/phonon-voices` | Apache-2.0 |
| [ptts](https://github.com/gradium-ai/xn-ptts), Phonon's Rust runtime (Python package) | PyPI | MIT or Apache-2.0 |
| numpy | PyPI | BSD-3-Clause |
| [uv](https://github.com/astral-sh/uv) and the Python it installs | astral.sh | MIT or Apache-2.0 / PSF |

Phonon builds on Kyutai's Pocket TTS and Mimi codec. Gradium asks that it not be used to impersonate a real person or to clone a voice without the speaker's consent; Poinky does neither.

## Services

Poinky sends your screenshots and questions to Claude (Anthropic), and search words to Wikipedia for photos. Their terms apply to that use.

## Inspiration

Inspired by [Clicky](https://github.com/farzaa/clicky).
