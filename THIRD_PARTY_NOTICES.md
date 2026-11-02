# Third-party notices

Poinky is MIT licensed (see [LICENSE](LICENSE)). It includes or downloads the following.

## Included in this repository

| Component | Where | License |
|---|---|---|
| [three.js](https://threejs.org) r160 | `vendor/three.min.js` | MIT, © 2010-2023 three.js authors |

## Downloaded by the installer (not stored in this repository)

The natural voice is installed on your Mac by `kokoro/install.sh`. Poinky only talks to it through a local helper process.

| Component | Source | License |
|---|---|---|
| [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) model, as ONNX files | [kokoro-onnx releases](https://github.com/thewh1teagle/kokoro-onnx/releases) | Apache-2.0 |
| [kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx) | PyPI | MIT |
| [onnxruntime](https://github.com/microsoft/onnxruntime), numpy and other Python dependencies | PyPI | MIT / BSD (see each package) |
| [espeakng-loader](https://github.com/thewh1teagle/espeakng-loader) and [phonemizer](https://github.com/bootphon/phonemizer) (use eSpeak NG for pronunciation) | PyPI | espeak-ng is GPL-3.0-or-later; run as a separate local process, not linked into Poinky |
| [uv](https://github.com/astral-sh/uv) and the Python it installs | astral.sh | MIT or Apache-2.0 / PSF |

## Services

Poinky sends your screenshots and questions to Claude (Anthropic), and search words to Wikipedia for photos. Their terms apply to that use.

## Inspiration

Inspired by [Clicky](https://github.com/farzaa/clicky).
