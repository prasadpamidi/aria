# Core AI proof model resources

Export Qwen3-0.6B from a checkout of Apple's `coreai-models` repository:

```bash
uv run coreai.llm.export Qwen/Qwen3-0.6B --platform iOS --output-dir ./exported-models
```

Copy the exported resource folder itself to:

```text
Tests/CoreAIProofTests/Resources/Qwen3-0.6B/
```

The final directory must contain the export's `metadata.json`, model asset, and
tokenizer resources. Model files are intentionally ignored by Git.
