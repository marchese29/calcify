from fastapi import FastAPI

app = FastAPI(title="calcify")


@app.get("/")
def root() -> dict[str, str]:
    return {"message": "Hello, world"}
