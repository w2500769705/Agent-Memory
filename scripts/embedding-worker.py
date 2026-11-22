import argparse
import json
from pathlib import Path
import sys

from fastembed import TextEmbedding
from huggingface_hub import snapshot_download

MODEL = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
REPOSITORY = "Qdrant/paraphrase-multilingual-MiniLM-L12-v2-onnx-Q"
REVISION = "faf4aa4225822f3bc6376869cb1164e8e3feedd0"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", required=True)
    parser.add_argument("--prepare", action="store_true")
    args = parser.parse_args()

    snapshot = Path(args.cache) / "models--Qdrant--paraphrase-multilingual-MiniLM-L12-v2-onnx-Q" / "snapshots" / REVISION
    if args.prepare:
        snapshot = Path(snapshot_download(
            REPOSITORY,
            revision=REVISION,
            cache_dir=args.cache,
            allow_patterns=["config.json", "model_optimized.onnx", "special_tokens_map.json",
                            "tokenizer.json", "tokenizer_config.json"],
        ))

    model = TextEmbedding(
        model_name=MODEL,
        cache_dir=args.cache,
        threads=2,
        specific_model_path=str(snapshot),
        local_files_only=True,
    )
    if args.prepare:
        next(iter(model.embed(["记忆 smoke test"])))
        return

    for line in sys.stdin:
        try:
            request = json.loads(line)
            vectors = [vector.tolist() for vector in model.embed(request["texts"], batch_size=16)]
            result = {"vectors": vectors}
        except (KeyError, TypeError, ValueError):
            result = {"vectors": []}
        print(json.dumps(result, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    main()
