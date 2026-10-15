# ciphertext packs land here

## OCI Vera

`oci-vera.enc` + `oci-vera.sha256` are produced on the Mac by:

```bash
OCI_PASS='four short words' GH_TOKEN=… bash scripts/host/oci pack
```

## NVIDIA Zen5 9755

`nvidia-zen5.enc` + `nvidia-zen5.sha256`:

```bash
NVIDIA_PASS='four short words' GH_TOKEN=… bash nvidia/scripts/pack_secrets.sh
```

On the box: `NVIDIA_PASS='…' ./o load` then `./o start`.

Commit the `.enc` + `.sha256` files. Never commit `*.plain`, `.env.oci`, or `.env.nvidia`.
