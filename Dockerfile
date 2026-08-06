FROM ghcr.io/astral-sh/uv:python3.12-bookworm-slim

WORKDIR /app

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev

COPY . .

ENV PATH="/app/.venv/bin:$PATH"
ENV PYTHONPATH="/app/workload/repos/sqlite-utils"
ENV PYTHONHASHSEED=0

ENTRYPOINT ["python", "main.py"]
CMD ["--n", "10"]
