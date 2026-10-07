# ciphertext packs land here

`oci-vera.enc` + `oci-vera.sha256` are produced on the Mac by:

```bash
OCI_PASS='four short words' GH_TOKEN=… bash scripts/host/oci pack
```

Commit those two files. Never commit `*.plain` or `.env.oci`.
