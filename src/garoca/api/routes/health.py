from fastapi import APIRouter

router = APIRouter()


@router.get("/health")
async def read_health():
    return {"status": "garoca is healthy"}