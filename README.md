# calcify

A chore tracker and reminder app that keeps all of its data in CalDAV. Chores are
stored as ordinary CalDAV tasks (VTODO), so any reminders client still works on
them, including Apple Reminders and Siri on an iPhone. calcify adds the features
those clients don't have.

Status: scaffold only. The only thing it does today is answer `GET /`.

## Develop

Requires [uv](https://docs.astral.sh/uv/).

```bash
uv sync                                                # install deps into .venv
uv run uvicorn calcify.app:app --reload                # dev server with reload, :8000
uv run calcify                                         # plain server, :8000
curl localhost:8000/                                   # {"message":"Hello, world"}
```
