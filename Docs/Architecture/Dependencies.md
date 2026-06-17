# Dependencies

Milestone 1 uses Swift Package Manager with exact dependency requirements and committed `Package.resolved` files.

Pinned files:
- `SupraAI.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `Packages/SupraStore/Package.resolved`

Build note:
On macOS 27 with Xcode 27 beta, MLX Swift requires the separate Metal Toolchain component. If the build fails with `cannot execute tool 'metal' due to missing Metal Toolchain`, install it with:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain
```

## GRDB.swift

Purpose:
Used for SQLite persistence through SupraStore.

Used by:
- SupraStore
- SupraAI.app

SPM product:
- `GRDB`

Pinned version/revision:
- `7.11.0`
- `9ed8c8457e00ff9c7aedb3bf213f20a2cfdf509e`

Update risk:
Database API changes may affect migrations and repositories.

## MLX Swift

Purpose:
Used by SupraRuntimeService for local MLX tensor/model runtime.

Used by:
- SupraRuntimeService.xpc

SPM product:
- `MLX`

Pinned version/revision:
- `0.31.4`
- `dc43e62d7055353c7f99fa071a4e71d29dfddc44`

Update risk:
Runtime API instability may affect model loading and inference.

## MLX Swift LM

Purpose:
Used by SupraRuntimeService for MLX language model implementations and generation.

Used by:
- SupraRuntimeService.xpc

SPM products:
- `MLXLLM`
- `MLXLMCommon`

Pinned version/revision:
- `3.31.3`
- `1c05248bb0899e2a7a4962b84d319cf12f4e12aa`

Update risk:
Model-loading/generation APIs may change.

Version posture:
`mlx-swift` 0.31.4 and `mlx-swift-lm` 3.31.3 are the latest upstream releases (as of June 2026); the project is current, not behind. The pins are `exactVersion` for reproducible builds — bump them deliberately rather than tracking `main`.

Model architecture support:
The runtime links only `MLXLLM`, whose `LLMModelFactory` dispatches on `config.json`'s `model_type` (looked up in `LLMTypeRegistry`) — not the `architectures` name. The download flow's `ModelCompatibility` mirrors that registry's `model_type` set and rejects unregistered types up front, before downloading weights; its set must be updated whenever `mlx-swift-lm` is bumped. Multimodal/vision-only models (whose `model_type` is absent from the LLM registry) require `MLXVLM` + a `VLMModelFactory` path, which is not linked — a separate runtime capability.

## MLX LM Tokenizers

Purpose:
Used by SupraRuntimeService to load local MLX model directories with tokenizer support. MLX Swift LM 3.x keeps tokenizer integrations outside the core package, so this bridge provides the local tokenizer loader used by `MLXModelController`.

Used by:
- SupraRuntimeService.xpc

SPM product:
- `MLXLMTokenizers`

Pinned version/revision:
- `0.3.0`
- `6fb48051a8b7e36707725d3ef2f876d6ed860250`

Update risk:
Tokenizer-loading or chat-template behavior changes may affect prompt formatting and local model compatibility.

## Transitive Dependencies

These packages are pinned by the workspace resolver because they are required by MLX Swift or MLX Swift LM:

### swift-numerics

Used by:
- MLX Swift

Pinned version/revision:
- `1.1.1`
- `0c0290ff6b24942dadb83a929ffaaa1481df04a2`

### swift-syntax

Used by:
- MLX Swift LM

Pinned version/revision:
- `600.0.1`
- `0687f71944021d616d34d922343dcef086855920`

### swift-tokenizers

Used by:
- MLX LM Tokenizers

Pinned version/revision:
- `0.5.0`
- `9cb02e836c1d8782a36ea02e7c437697ceff2ab8`

Pinning note:
This package is held at `0.5.0` by an exact workspace constraint because `swift-tokenizers-mlx` 0.3.0 does not yet compile against the throwing encode/decode APIs introduced by later `swift-tokenizers` releases.
