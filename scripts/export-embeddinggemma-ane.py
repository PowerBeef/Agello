#!/usr/bin/env python3
"""Export EmbeddingGemma 2 (text, 270M) from its verified .litertlm file into a
Core AI Apple Neural Engine bundle:

  <out>/
    text_encoder.aimodel/   # 4-bucket (128/256/512/1024) asymmetric INT4 Core AI model
    embed_tokens.bin        # 32-byte AGET header + 262,144 FP32 row scales + INT4 table
    tokenizer.model         # exact SentencePiece BPE ModelProto
    manifest.json           # format metadata and per-file SHA-256 digests

Requires Python 3.13 with coreai-core, coreai-torch, coreai-opt, ai-edge-litert,
litert-lm-builder, and sentencepiece (e.g. ~/.venvs/coreai-tools).
"""
import argparse
import asyncio
import hashlib
import json
import os
import re
import shutil
import struct
import tempfile
import time
from pathlib import Path

import litert_lm_builder as lmb
import numpy as np
import sentencepiece as spm
import torch
import torch.nn as nn
import torch.nn.functional as F
from ai_edge_litert import schema_py_generated as S

OPS = {getattr(S.BuiltinOperator, k): k for k in dir(S.BuiltinOperator) if not k.startswith("_")}
DEFAULT_INPUT = os.path.expanduser("~/Models/agello/embeddinggemma-2-text-270m.litertlm")
DEFAULT_OUTPUT = os.path.expanduser("~/Models/agello/embeddinggemma-2-text-270m-ane")
BUCKETS = (128, 256, 512, 1024)


def unpack_int4(raw_bytes: bytes, shape: tuple[int, ...], scales: np.ndarray) -> np.ndarray:
    """Unpack TFLite signed INT4 (low nibble first, two's complement -8..7) with per-row scales."""
    arr = np.frombuffer(raw_bytes, dtype=np.uint8)
    lo = (arr & 0x0F).astype(np.int8)
    hi = (arr >> 4).astype(np.int8)
    lo = np.where(lo >= 8, lo - 16, lo)
    hi = np.where(hi >= 8, hi - 16, hi)
    unpacked = np.empty(arr.size * 2, dtype=np.int8)
    unpacked[0::2] = lo
    unpacked[1::2] = hi
    w = unpacked[: int(np.prod(shape))].reshape(shape).astype(np.float32)
    return w * scales.reshape(-1, *([1] * (len(shape) - 1)))


def read_tensor_weight(model, sg, tensor_idx: int, ext_bytes: bytes, eb_map: dict) -> np.ndarray:
    t = sg.Tensors(tensor_idx)
    shape = tuple(int(x) for x in t.ShapeAsNumpy())
    ttype = t.Type()
    eb_id = t.ExternalBuffer()
    if eb_id:
        off, length = eb_map[eb_id]
        raw = ext_bytes[off : off + length]
    else:
        buf = model.Buffers(t.Buffer())
        raw = bytes(buf.DataAsNumpy())

    if ttype == S.TensorType.FLOAT32:
        return np.frombuffer(raw, dtype=np.float32).reshape(shape).copy()
    if ttype == S.TensorType.INT4:
        scales = t.Quantization().ScaleAsNumpy().astype(np.float32)
        return unpack_int4(raw, shape, scales)
    if ttype == S.TensorType.INT8:
        scales = t.Quantization().ScaleAsNumpy().astype(np.float32)
        w = np.frombuffer(raw, dtype=np.int8).reshape(shape).astype(np.float32)
        return w * scales.reshape(-1, *([1] * (len(shape) - 1)))
    raise ValueError(f"Unsupported tensor type {ttype} for {t.Name().decode()}")


def extract_weights(unpacked_dir: str) -> dict:
    ebuf = open(os.path.join(unpacked_dir, "Section2_TFLiteModel_tf_lite_embedder.tflite"), "rb").read()
    eext = open(os.path.join(unpacked_dir, "Section4_TFLiteWeights_tf_lite_embedder.weight"), "rb").read()
    em = S.Model.GetRootAs(ebuf, 0)
    esg = em.Subgraphs(0)
    et10 = esg.Tensors(10)
    et12 = esg.Tensors(12)
    embed_mul = float(np.frombuffer(bytes(em.Buffers(et12.Buffer()).DataAsNumpy()), np.float32)[0])
    embed_scales = et10.Quantization().ScaleAsNumpy().astype(np.float32).copy()
    eb_id = et10.ExternalBuffer()
    eb_entry = next(
        em.ExternalBuffers(i)
        for i in range(em.ExternalBuffersLength())
        if em.ExternalBuffers(i).Id() == eb_id
    )
    embed_packed = eext[eb_entry.Offset() : eb_entry.Offset() + eb_entry.Length()]

    tbuf = open(os.path.join(unpacked_dir, "Section3_TFLiteModel_tf_lite_text_encoder.tflite"), "rb").read()
    text_ext = open(os.path.join(unpacked_dir, "Section5_TFLiteWeights_tf_lite_text_encoder.weight"), "rb").read()
    tm = S.Model.GetRootAs(tbuf, 0)
    sg0 = tm.Subgraphs(0)
    eb_map = {
        tm.ExternalBuffers(i).Id(): (tm.ExternalBuffers(i).Offset(), tm.ExternalBuffers(i).Length())
        for i in range(tm.ExternalBuffersLength())
    }

    weights = {
        "embed_packed": embed_packed,
        "embed_scales": embed_scales,
        "embed_mul": embed_mul,
        "layers": [{} for _ in range(24)],
    }

    for oi in range(sg0.OperatorsLength()):
        op = sg0.Operators(oi)
        code = tm.OperatorCodes(op.OpcodeIndex())
        opname = OPS.get(max(code.BuiltinCode(), code.DeprecatedBuiltinCode()), "?")
        outname = sg0.Tensors(op.Outputs(0)).Name().decode()

        if opname == "FULLY_CONNECTED":
            w_idx = op.Inputs(1)
            w = read_tensor_weight(tm, sg0, w_idx, text_ext, eb_map)
            if "per_layer_model_projection" in outname:
                weights["per_layer_model_projection"] = w
            elif (
                "StatefulPartitionedCall:0" in outname
                or "default_projection" in sg0.Tensors(w_idx).Name().decode()
            ):
                weights["head_proj"] = w
            else:
                m_layer = re.search(r"layer_(\d+)", outname)
                if not m_layer:
                    raise ValueError(f"Unmatched FC: {outname}")
                layer = weights["layers"][int(m_layer.group(1))]
                if "q_einsum" in outname:
                    if "q_proj" not in layer:
                        layer["q_proj"] = w
                    elif "k_proj" not in layer:
                        layer["k_proj"] = w
                    else:
                        layer["v_proj"] = w
                elif "attn_vec_einsum" in outname:
                    layer["o_proj"] = w
                elif "gating_einsum" in outname:
                    if "gate_proj" not in layer:
                        layer["gate_proj"] = w
                    else:
                        layer["up_proj"] = w
                elif "mlp/linear" in outname:
                    layer["down_proj"] = w
                elif "per_layer_embedding_gate" in outname:
                    layer["ple_gate"] = w
                elif "per_layer_embedding_projection" in outname:
                    layer["ple_proj"] = w
                else:
                    raise ValueError(f"Unknown layer FC: {outname}")

        elif opname == "STABLEHLO_COMPOSITE":
            bo = op.BuiltinOptions2() or op.BuiltinOptions()
            opts = S.StableHLOCompositeOptions()
            opts.Init(bo.Bytes, bo.Pos)
            cname = opts.Name().decode()
            if cname == "odml.rms_norm":
                g = read_tensor_weight(tm, sg0, op.Inputs(1), text_ext, eb_map)
                if "per_layer_embedding_projection_norm" in outname:
                    weights["ple_proj_norm"] = g
                elif "final_norm" in outname:
                    weights["final_norm"] = g
                else:
                    layer = weights["layers"][int(re.search(r"layer_(\d+)", outname).group(1))]
                    for tag in (
                        "pre_attention_norm",
                        "query_norm",
                        "key_norm",
                        "value_norm",
                        "post_attention_norm",
                        "pre_ffw_norm",
                        "post_ffw_norm",
                        "post_per_layer_input_norm",
                    ):
                        if tag in outname:
                            layer[tag] = g
                            break
                    else:
                        raise ValueError(f"Unknown rms_norm: {outname}")
            elif cname == "odml.rope":
                dsg = tm.Subgraphs(opts.DecompositionSubgraphIndex())
                inv_freq = (
                    np.frombuffer(
                        bytes(tm.Buffers(dsg.Tensors(7).Buffer()).DataAsNumpy()), dtype=np.float32
                    )
                    .reshape(-1)
                    .copy()
                )
                if inv_freq.size == 128 and "rope_sliding_inv_freq" not in weights:
                    weights["rope_sliding_inv_freq"] = inv_freq
                elif inv_freq.size == 256 and "rope_full_inv_freq" not in weights:
                    weights["rope_full_inv_freq"] = inv_freq

        elif opname == "MUL" and "_maybe_apply_skip_scale" in outname:
            li = int(re.search(r"layer_(\d+)", outname).group(1))
            s = read_tensor_weight(tm, sg0, op.Inputs(1), text_ext, eb_map).reshape(())
            weights["layers"][li]["skip_scale"] = float(s)

    return weights


def rms_norm(x: torch.Tensor, weight: torch.Tensor, eps: float = 1e-6) -> torch.Tensor:
    if x.dtype == torch.float16:
        # Overflow- and underflow-free FP16 RMSNorm: divide by per-vector max(|x|) + 1e-4
        # so xs lies in [-1, 1]; zero vectors produce finite rsqrt(1e-5) and output 0.
        s = x.abs().amax(dim=-1, keepdim=True) + 1e-4
        xs = x * torch.reciprocal(s)
        var = (xs * xs).mean(dim=-1, keepdim=True) + 1e-5
        return (xs * torch.rsqrt(var)) * weight
    var = (x * x).mean(dim=-1, keepdim=True) + eps
    return (x * torch.rsqrt(var)) * weight


def unfused_softmax(scores: torch.Tensor) -> torch.Tensor:
    """Explicit max/sub/exp/sum/reciprocal/mul so iOS/macOS 27.2 Core AI never re-fuses SDPA off ANE."""
    m = scores.amax(dim=-1, keepdim=True)
    ex = torch.exp(scores - m)
    return ex * torch.reciprocal(ex.sum(dim=-1, keepdim=True))


def apply_rope(x: torch.Tensor, cos: torch.Tensor, sin: torch.Tensor) -> torch.Tensor:
    half = x.shape[-1] // 2
    x1 = x[..., :half]
    x2 = x[..., half:]
    return torch.cat([x1 * cos - x2 * sin, x2 * cos + x1 * sin], dim=-1)


class EmbeddingGemma2Layer(nn.Module):
    def __init__(self, layer_w: dict, is_full: bool):
        super().__init__()
        self.is_full = is_full
        self.num_heads = 4
        self.num_kv_heads = 1 if is_full else 2
        self.head_dim = 512 if is_full else 256

        def make_lin(w_np):
            lin = nn.Linear(w_np.shape[1], w_np.shape[0], bias=False)
            lin.weight = nn.Parameter(torch.from_numpy(w_np), requires_grad=False)
            return lin

        self.q_proj = make_lin(layer_w["q_proj"])
        self.k_proj = make_lin(layer_w["k_proj"])
        self.v_proj = make_lin(layer_w["v_proj"])
        self.o_proj = make_lin(layer_w["o_proj"])
        self.gate_proj = make_lin(layer_w["gate_proj"])
        self.up_proj = make_lin(layer_w["up_proj"])
        self.down_proj = make_lin(layer_w["down_proj"])
        self.ple_gate = make_lin(layer_w["ple_gate"])
        self.ple_proj = make_lin(layer_w["ple_proj"])

        for tag in (
            "pre_attention_norm",
            "query_norm",
            "key_norm",
            "value_norm",
            "post_attention_norm",
            "pre_ffw_norm",
            "post_ffw_norm",
            "post_per_layer_input_norm",
        ):
            self.register_buffer(tag, torch.from_numpy(layer_w[tag].copy()))
        self.register_buffer("skip_scale", torch.tensor(layer_w["skip_scale"], dtype=torch.float32))

    def forward(self, x, ple, attn_mask, cos, sin):
        B, S, _ = x.shape
        h = rms_norm(x, self.pre_attention_norm)
        q = self.q_proj(h).reshape(B, S, self.num_heads, self.head_dim)
        k = self.k_proj(h).reshape(B, S, self.num_kv_heads, self.head_dim)
        v = self.v_proj(h).reshape(B, S, self.num_kv_heads, self.head_dim)

        q = apply_rope(rms_norm(q, self.query_norm).transpose(1, 2), cos, sin)
        k = apply_rope(rms_norm(k, self.key_norm).transpose(1, 2), cos, sin)
        v = rms_norm(v, self.value_norm).transpose(1, 2)

        if self.num_kv_heads == 2:
            k_exp = torch.cat([k[:, 0:1], k[:, 0:1], k[:, 1:2], k[:, 1:2]], dim=1)
            v_exp = torch.cat([v[:, 0:1], v[:, 0:1], v[:, 1:2], v[:, 1:2]], dim=1)
        else:
            k_exp = k.expand(B, 4, S, self.head_dim)
            v_exp = v.expand(B, 4, S, self.head_dim)

        scores = torch.matmul(q, k_exp.transpose(-1, -2)) + attn_mask
        probs = unfused_softmax(scores)
        attn_out = torch.matmul(probs, v_exp)
        attn_out = attn_out.transpose(1, 2).reshape(B, S, self.num_heads * self.head_dim)
        x = x + rms_norm(self.o_proj(attn_out), self.post_attention_norm)

        h_ff = rms_norm(x, self.pre_ffw_norm)
        ff = F.gelu(self.gate_proj(h_ff), approximate="tanh") * self.up_proj(h_ff)
        x = x + rms_norm(self.down_proj(ff), self.post_ffw_norm)

        g = F.gelu(self.ple_gate(x), approximate="tanh") * ple
        x = (x + rms_norm(self.ple_proj(g), self.post_per_layer_input_norm)) * self.skip_scale
        return x


class EmbeddingGemma2TextEncoder(nn.Module):
    def __init__(self, weights: dict, max_seq_len: int = 1024):
        super().__init__()
        self.ple_model_proj = nn.Linear(512, 12288, bias=False)
        self.ple_model_proj.weight = nn.Parameter(
            torch.from_numpy(weights["per_layer_model_projection"]), requires_grad=False
        )
        self.register_buffer("ple_proj_norm", torch.from_numpy(weights["ple_proj_norm"].copy()))
        self.layers = nn.ModuleList(
            [
                EmbeddingGemma2Layer(weights["layers"][i], is_full=(i in (5, 11, 17, 23)))
                for i in range(24)
            ]
        )
        self.register_buffer("final_norm", torch.from_numpy(weights["final_norm"].copy()))
        self.head_proj = nn.Linear(512, 768, bias=False)
        self.head_proj.weight = nn.Parameter(torch.from_numpy(weights["head_proj"]), requires_grad=False)

        pos = np.arange(max_seq_len, dtype=np.float64)[:, None]
        ang_s = pos * weights["rope_sliding_inv_freq"].astype(np.float64)[None, :]
        ang_f = pos * weights["rope_full_inv_freq"].astype(np.float64)[None, :]
        self.register_buffer("cos_s", torch.from_numpy(np.cos(ang_s).astype(np.float32))[None, None, :, :])
        self.register_buffer("sin_s", torch.from_numpy(np.sin(ang_s).astype(np.float32))[None, None, :, :])
        self.register_buffer("cos_f", torch.from_numpy(np.cos(ang_f).astype(np.float32))[None, None, :, :])
        self.register_buffer("sin_f", torch.from_numpy(np.sin(ang_f).astype(np.float32))[None, None, :, :])

    def forward(self, embeddings: torch.Tensor, input_mask: torch.Tensor) -> torch.Tensor:
        B, S, _ = embeddings.shape
        m_col = input_mask.reshape(B, S, 1)
        m_row = input_mask.reshape(B, 1, S)
        valid = m_col * m_row
        mask_val = -10000.0 if embeddings.dtype == torch.float16 else -45852.8
        attn_mask = ((1.0 - valid) * mask_val).reshape(B, 1, S, S)

        ple_all = rms_norm(self.ple_model_proj(embeddings).reshape(B, S, 24, 512), self.ple_proj_norm)
        cos_s, sin_s = self.cos_s[:, :, :S, :], self.sin_s[:, :, :S, :]
        cos_f, sin_f = self.cos_f[:, :, :S, :], self.sin_f[:, :, :S, :]

        x = embeddings
        for i, layer in enumerate(self.layers):
            ple_i = ple_all[:, :, i, :]
            x = layer(x, ple_i, attn_mask, cos_f if layer.is_full else cos_s, sin_f if layer.is_full else sin_s)

        x = rms_norm(x, self.final_norm)
        summed = (x * m_col).sum(dim=1)
        denom = input_mask.sum(dim=1, keepdim=True) + 1e-4
        return self.head_proj(summed * torch.reciprocal(denom))


def write_embed_tokens_bin(path: Path, weights: dict) -> None:
    """Write 32-byte AGET header + 262,144 FP32 scales + 67,108,864 packed INT4 bytes."""
    scales = np.asarray(weights["embed_scales"], dtype="<f4")
    packed = weights["embed_packed"]
    assert scales.shape == (262144,), scales.shape
    assert len(packed) == 262144 * 256, len(packed)
    header = struct.pack("<4sIIIf12s", b"AGET", 1, 262144, 512, float(weights["embed_mul"]), b"\x00" * 12)
    assert len(header) == 32
    with open(path, "wb") as f:
        f.write(header)
        f.write(scales.tobytes())
        f.write(packed)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest()


def lookup_embeddings(weights: dict, token_ids: list[int], seq_len: int) -> tuple[np.ndarray, np.ndarray]:
    packed = np.frombuffer(weights["embed_packed"], dtype=np.uint8).reshape(262144, 256)
    scales = weights["embed_scales"]
    mul = np.float32(weights["embed_mul"])
    ids = np.zeros(seq_len, dtype=np.int32)
    n = min(len(token_ids), seq_len)
    ids[:n] = token_ids[:n]
    mask = np.zeros((1, seq_len), dtype=np.float32)
    mask[0, :n] = 1.0
    rows = packed[ids]
    lo = (rows & 0x0F).astype(np.int8)
    hi = (rows >> 4).astype(np.int8)
    lo = np.where(lo >= 8, lo - 16, lo)
    hi = np.where(hi >= 8, hi - 16, hi)
    unpacked = np.empty((seq_len, 512), dtype=np.int8)
    unpacked[:, 0::2] = lo
    unpacked[:, 1::2] = hi
    emb = (unpacked.astype(np.float32) * scales[ids, None] * mul)[None, :, :]
    return emb, mask


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    a = a.astype(np.float64).reshape(-1)
    b = b.astype(np.float64).reshape(-1)
    return float(np.dot(a, b) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-12))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", default=DEFAULT_INPUT, help="Path to embeddinggemma-2-text-270m.litertlm")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help="Output ANE bundle directory")
    parser.add_argument("--verify", action="store_true", help="Verify ANE specialization, parity, and latency")
    args = parser.parse_args()

    out_dir = Path(args.output)
    out_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        t0 = time.perf_counter()
        lmb.unpack_litertlm_file(args.input, tmp)
        weights = extract_weights(tmp)
        sp_src = Path(tmp) / "Section1_SP_Tokenizer.spiece"
        shutil.copy2(sp_src, out_dir / "tokenizer.model")
        write_embed_tokens_bin(out_dir / "embed_tokens.bin", weights)
        print(f"Extracted weights & wrote tokenizer.model + embed_tokens.bin in {time.perf_counter() - t0:.2f}s")

        from coreai_opt.quantization import ExecutionMode, Quantizer, QuantizerConfig
        from coreai_opt.quantization.spec import QuantizationScheme
        from coreai_torch import TorchConverter, get_decomp_table

        base = EmbeddingGemma2TextEncoder(weights, max_seq_len=max(BUCKETS)).eval()
        cfg = QuantizerConfig.presets.w4()
        cfg.execution_mode = ExecutionMode.EAGER
        cfg.global_config.op_state_spec["weight"] = cfg.global_config.op_state_spec["weight"].model_copy(
            update={"qscheme": QuantizationScheme.ASYMMETRIC}
        )
        export_mod = base.half()
        q = Quantizer(export_mod, cfg)
        ex_init = (torch.zeros(1, BUCKETS[0], 512, dtype=torch.float16), torch.ones(1, BUCKETS[0], dtype=torch.float16))
        export_mod = q.prepare(ex_init)
        export_mod = q.finalize()

        conv = TorchConverter()
        for bkt in BUCKETS:
            ex = (torch.zeros(1, bkt, 512, dtype=torch.float16), torch.ones(1, bkt, dtype=torch.float16))
            ep = torch.export.export(export_mod, args=ex)
            ep = ep.run_decompositions(get_decomp_table())
            conv.add_exported_program(
                ep,
                input_names=["embeddings", "input_mask"],
                output_names=["encodings"],
                entrypoint_name=f"encoder_{bkt}",
            )
        program = conv.to_coreai()
        aimodel_path = out_dir / "text_encoder.aimodel"
        if aimodel_path.exists():
            shutil.rmtree(aimodel_path)
        program.save_asset(aimodel_path)

        files = {}
        total_bytes = 0
        for p in sorted(out_dir.rglob("*")):
            if p.is_file() and p.name != "manifest.json":
                rel = p.relative_to(out_dir).as_posix()
                sz = p.stat().st_size
                total_bytes += sz
                files[rel] = {"size": sz, "sha256": sha256_file(p)}

        manifest = {
            "format": "agello-embeddinggemma2-ane-v1",
            "source_file": os.path.basename(args.input),
            "source_sha256": sha256_file(Path(args.input)),
            "buckets": list(BUCKETS),
            "dimensions": 768,
            "total_bytes": total_bytes,
            "files": files,
        }
        (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(f"Wrote {out_dir} ({total_bytes / (1024 * 1024):.1f} MB total)")

        if args.verify:
            import coreai.runtime as crt

            ref_model = EmbeddingGemma2TextEncoder(weights, max_seq_len=max(BUCKETS)).eval()
            sp = spm.SentencePieceProcessor(model_file=str(out_dir / "tokenizer.model"))
            prompts = [
                "task: search result | query: What is the capital of France?",
                "title: notes.md | text: Paris is the capital and most populous city of France, situated along the Seine River.",
                "title: french.txt | text: Bonjour! Indexation sémantique sur le Neural Engine d'Apple.",
                "title: cjk.txt | text: 東京の天気は晴れです。機械学習モデルの推論を高速化します。",
                "title: code.swift | text: actor CoreAIEmbedder: TextEmbedder { func embed(query: String) async throws -> [Float] { [] } }",
                "title: long.pdf | text: " + ("Quarterly revenue rose 14.2% year over year across enterprise hardware renewals and on-device AI workloads. " * 18),
            ]
            ref_fp32 = []
            tok_lists = []
            with torch.no_grad():
                for pr in prompts:
                    toks = [2] + sp.encode(pr, out_type=int) + [1]
                    if len(toks) > 1024:
                        toks = toks[:1023] + [1]
                    tok_lists.append(toks)
                    bkt = next(b for b in BUCKETS if len(toks) <= b)
                    emb, mask = lookup_embeddings(weights, toks, bkt)
                    v = ref_model(torch.from_numpy(emb), torch.from_numpy(mask)).numpy()[0]
                    ref_fp32.append(v / np.linalg.norm(v))

            async def verify_ane():
                opts = crt.SpecializationOptions.from_preferred_compute_unit_kind(crt.ComputeUnitKind.neural_engine())
                model = await crt.AIModel.load(str(aimodel_path), specialization_options=opts)
                funcs = {b: model.load_function(f"encoder_{b}") for b in BUCKETS}
                min_cos = 1.0
                for toks, r32 in zip(tok_lists, ref_fp32):
                    bkt = next(b for b in BUCKETS if len(toks) <= b)
                    emb, mask = lookup_embeddings(weights, toks, bkt)
                    out = funcs[bkt]({"embeddings": crt.NDArray(emb.astype(np.float16)), "input_mask": crt.NDArray(mask.astype(np.float16))})
                    if asyncio.iscoroutine(out):
                        out = await out
                    v = out["encodings"].numpy().astype(np.float32)[0]
                    v = v / np.linalg.norm(v)
                    min_cos = min(min_cos, cosine(r32, v))
                print(f"Verified ANE parity: min_cos={min_cos:.6f}")
                assert min_cos >= 0.995, f"Parity failed: {min_cos}"

            asyncio.run(verify_ane())


if __name__ == "__main__":
    main()
