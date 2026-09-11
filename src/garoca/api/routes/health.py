from garoca.api import app


@app.get("/health")
async def read_health():
    return {"status": "garoca is healthy"}