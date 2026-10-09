# StableDiffusion (vendored)

Swift pipeline of [apple/ml-stable-diffusion](https://github.com/apple/ml-stable-diffusion) (MIT, see LICENSE.md),
commit ea2805dc1945be20561c77e5f6d1d9a5a637cda2, copied here so MusicAmp builds with no package dependencies.
Left out: the Stable Diffusion 3 pipeline and resources and the T5 text encoder/tokenizer (they need swift-transformers).
Used by Live Video with Core ML models the user sideloads (SDXL, SD 2.1); see docs/live-video.md.
