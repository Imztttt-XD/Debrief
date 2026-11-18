# Third-party components

Used only by the experimental speaker separation (设置 → 通用 → 实验功能). Not stored in this
repository: the libraries are fetched by `scripts/fetch-sherpa.sh` and bundled by `build-app.sh`; the
models are downloaded by the app on first use.

| Component | Version / file | License | Source |
|---|---|---|---|
| sherpa-onnx (C API, `libsherpa-onnx-c-api.dylib`; header in `Sources/CSherpaOnnx/c-api.h`) | v2.0.1 | Apache-2.0 | https://github.com/k2-fsa/sherpa-onnx |
| ONNX Runtime (`libonnxruntime.dylib`, shipped inside the sherpa-onnx release) | as bundled by sherpa-onnx v2.0.1 | MIT (to be confirmed against the ONNX Runtime repository before a public release) | https://onnxruntime.ai |
| pyannote segmentation 3.0 (`segmentation.onnx`, ONNX export by sherpa-onnx) | 3.0 | MIT | https://huggingface.co/pyannote/segmentation-3.0 |
| 3D-Speaker CAM++ zh-cn 16k (`embedding.onnx`) | `3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx` | Apache-2.0 | https://github.com/modelscope/3D-Speaker |
