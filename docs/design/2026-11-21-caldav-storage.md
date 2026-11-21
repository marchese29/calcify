# CalDAV as calcify's storage layer

Date: 2026-11-21
Status: draft for review. Nothing here is implemented yet.

## Summary

Calcify is a server and web client that points at a CalDAV account the user
already has. It stores every task as an ordinary CalDAV task (a `VTODO`), so
existing clients such as Apple Reminders with Siri keep working on the same
data. Calcify adds three things those clients lack: repeating chores that
behave sensibly, assignment to household members, and simple "when X is done,
create Y" rules.

All task data lives in CalDAV. Calcify's own storage is limited to things that
are not tasks: a config file, a small database for sign-in accounts, and an
in-memory copy of the tasks, used for querying, that is rebuilt from the
server.

## Tenets

1. **Compatibility is best effort.** If a feature has no native CalDAV
   representation, it works only in calcify's own client. We do not bend the
   design to surface it elsewhere.
2. **We never break other clients.** Everything calcify writes is a valid
   `VTODO` that a client with no knowledge of calcify can display and edit.
3. **Native fields first.** If the iCalendar standard has a field for
   something, that field is the source of truth. Calcify-specific properties
   hold only what has no native home.
4. **Every task is a calcify task.** A reminder created by Siri has no
   calcify properties and is still shown and managed. Calcify properties are
   optional enrichment.
5. **We accept the risk of data loss by other clients.** A third-party client
   might drop calcify's properties when it edits a task. We live with that
   unless testing shows it is common.

## Architecture

```
 phone / desktop clients ──┐
 (Reminders, Siri, ...)    │
                           ▼
                     CalDAV server  (user's own: Stalwart, Radicale, ...)
                           ▲
                           │ python-caldav, async
                     calcify server (FastAPI)
                       ├─ sync poller      detects changes made by anyone
                       ├─ reactor          rolls repeats forward, fires rules
                       └─ HTTP API  ◄────  calcify web client
```

- **Sync poller.** CalDAV generally has no push. Calcify polls each task list
  using sync tokens (RFC 6578), which return only the objects that changed
  since the last poll. A poll interval of 30 to 60 seconds is the starting
  point; it is also the worst-case delay before a rule fires.
- **Reactor.** Looks at each changed task and decides whether calcify owes a
  follow-up write: rolling a repeating task forward, or creating the task a
  rule asks for. It reacts the same way whether the change came from calcify's
  client or from someone ticking a box in Reminders.
- **Local copy.** Calcify never asks the CalDAV server to answer a query. It
  loads every task into a local copy, keeps that copy current through the sync
  poller, and runs all filtering and sorting there. CalDAV servers cannot
  query on custom properties, and a household has few enough tasks that
  holding all of them is cheap.

  The copy is plain in-memory objects. At household scale, RAM is ample even
  for years of tasks, and having no parallel database means there is nothing
  to keep in step with CalDAV beyond the copy itself. It is derived data:
  CalDAV stays the only source of truth, and the copy and its sync tokens are
  rebuilt from the server on every start. SQLite remains an option if this
  ever proves wrong, but it is not planned.

- **Push instead of polling (stretch goal).** Some CalDAV servers can notify
  a listener when data changes, through webhooks or the draft WebDAV-Push
  standard. Where that is available, calcify could run a sync when notified
  and drop the polling loop, or slow it to an occasional safety check. The
  sync itself would not change: a notification only says "something changed",
  and the sync token still fetches what. Polling stays the baseline because
  it works on every server. Whether Stalwart's webhooks cover calendar
  changes has not been checked.

### What lives outside CalDAV

Two things, and neither holds task data.

- **Config file.** The CalDAV URL and credentials, sign-in provider settings,
  and any task lists to leave alone.
- **Accounts database.** A small SQLite database for calcify's own sign-in
  data: household members, password hashes, links to single sign-on
  identities, and sessions. See "Sign-in" below.

The rule for the database is that it holds only what belongs to calcify and
has no meaning to a CalDAV client. Tasks, and everything about a task, stay
in CalDAV. This keeps the benefit of having no parallel task store: there is
no second copy of a task to keep in step.

The one link between the two is the assignee. A task names a member by id,
and the member is a row in the database. If a member is removed, their tasks
remain and show an unknown assignee until reassigned.

### Task lists

Calcify supports multiple task lists. Each CalDAV task list on the account
appears as a list in calcify, and each has its own sync token. By default
calcify manages every list on the account that can hold tasks; the config
file can exclude some. A task created by a rule goes in the same list as the
task that triggered it.

## Data model

### Native fields

| Concept | iCalendar field |
|---|---|
| Title, notes | `SUMMARY`, `DESCRIPTION` |
| Due and start | `DUE`, `DTSTART` (always written with a timezone) |
| Done or not | `STATUS`, `COMPLETED` |
| Notification | `VALARM` |
| Repeats on a schedule | `RRULE` |
| Link between tasks | `RELATED-TO` |
| Priority, tags | `PRIORITY`, `CATEGORIES` |

### Calcify properties

| Property | Value | Purpose |
|---|---|---|
| `X-CALCIFY-ASSIGNEE` | member id, e.g. `dan` | Who the task is assigned to |
| `X-CALCIFY-REPEAT` | `after:<duration>` or `on-demand` | Repeat modes `RRULE` cannot express |
| `X-CALCIFY-ON-COMPLETE` | base64 of a JSON rule | What to create when this task is completed |

### Encoding rule

- **Scalar values are plain text** with no commas, semicolons or newlines.
- **Structured values are base64-encoded JSON.** The JSON carries a `"v"`
  version field.

This rule comes from testing. Radicale silently truncates a custom property at
its first unescaped comma and still answers `201 Created`. Escaping the commas
survives on the server, but the `icalendar` library does not unescape unknown
properties when reading. Base64 passes through both unchanged.

## Features

### Assignment

`X-CALCIFY-ASSIGNEE` names one household member by a stable id that never
changes, even if the member is renamed. Members
are unrelated to CalDAV identities: calcify talks to the server with one
shared account for the household, and "who" is purely calcify's concept. One
account is the decision for now. Per-member accounts would mean holding
several sets of credentials and merging lists, and can be revisited if the
project heads that way.

We do not use the native `ATTENDEE` and `ORGANIZER` fields. They require email
identities and can cause the server to send invitation emails.

Unassigned tasks, including everything created outside calcify, are shown as
unassigned.

### Sign-in

Members sign in to calcify in one of two ways.

- **Username and password.** The simple default, with accounts created inside
  calcify.
- **Single sign-on through OpenID Connect (OIDC).** For households that
  already run an identity provider, so existing accounts can be used. An OIDC
  identity is linked to a calcify member.

Both lead to the same member record, which is what tasks are assigned to.
Signing in to calcify is unrelated to the CalDAV account: members never see or
need the CalDAV credentials.

This is the reason calcify has a database at all. The details, such as the
library choice and how the first account is created, are not designed yet.

### Repeating tasks

There are three repeat modes.

| Mode | Stored as | Example |
|---|---|---|
| On a schedule | native `RRULE` | Bins out every Tuesday |
| After completion | `X-CALCIFY-REPEAT:after:P4D` | Water plants 4 days after last done |
| On demand | `X-CALCIFY-REPEAT:on-demand` | "Start dishwasher": no due date, always available |

The three modes are agreed. The roll-forward mechanics below are a sketch and
are deliberately not settled yet. They depend on how real clients write a
completed repeating task, which is untested.

**Roll-forward (sketch).** One `VTODO` represents the chore. When the reactor
sees a repeating task with `STATUS:COMPLETED`, it:

1. Writes a completed copy as a separate, non-repeating `VTODO` linked to the
   original with `RELATED-TO`. This is the history entry.
2. Resets the original to not-done and moves `DTSTART` and `DUE` to the next
   occurrence: the next `RRULE` slot, or completion time plus the duration, or
   no date for on-demand.

Because the trigger is "repeating task is marked completed", the logic is
stateless and cannot roll the same completion twice. If another client rolls a
task forward itself and leaves it not-done, calcify sees nothing to do.

**History.** The preference is to keep completion history in CalDAV, as the
completed copies above, and to keep all of it. There is no reason to throw
data away, and it stays visible to other clients. The condition is that
clients do not commonly delete old completed tasks on their own. If testing
shows they do, history moves to calcify's database instead.

Calcify implements roll-forward itself. python-caldav has a helper for completing
recurring tasks, but in testing it produced a next due date based on the
completion time, not the schedule, and it cannot express the other two modes.

### Rules: when X is done, create Y

A rule is stored on the task that triggers it, in `X-CALCIFY-ON-COMPLETE`.
Decoded, the dishwasher example is:

```json
{"v": 1, "summary": "Empty dishwasher", "due_in": "PT4H", "assignee": "dan"}
```

When the reactor sees the trigger task completed, it creates the follow-up
task with a `VALARM` at its due time, so phones notify without calcify being
involved. If the trigger task also repeats, roll-forward then happens as
above. "Start dishwasher" is therefore an on-demand repeating task with a
rule attached.

**Firing exactly once.** The follow-up task's UID is derived from the trigger
task's UID and its `COMPLETED` timestamp. It is created with
`If-None-Match: *`, so a second attempt after a restart or a repeated poll
fails harmlessly on the server. No local record of fired rules is needed.

Rules that are not attached to a task, or that have conditions, are out of
scope for now.

### Concurrent edits

Every write sends the task's ETag with `If-Match`. If another client changed
the task in the meantime, the server refuses, and calcify re-reads the task
and reapplies its change. CalDAV has no transactions, so the two writes in a
roll-forward are ordered to be safe to repeat: history copy first, then the
reset.

## Library

**python-caldav 3.7.0**, with `icalendar` 7 underneath.

- It is the only maintained full CalDAV client for Python.
- It has an async client (`caldav.aio`), which fits FastAPI.
- It exposes the raw `icalendar` component, which is how we read and write
  custom properties.
- It supports sync tokens and ETags.

The alternative, building on `httpx` and `icalendar` directly, means
re-solving server discovery and per-server quirks for no clear gain.

## What has been tested

A throwaway spike ran on Python 3.15 on aarch64 against a local Radicale.

| Check | Result |
|---|---|
| python-caldav and `lxml` install on Python 3.15 / aarch64 | Works |
| Async client connects, creates a list, reads and writes tasks | Works |
| Plain scalar `X-CALCIFY-*` property round-trips | Yes |
| `RRULE` and `CATEGORIES` kept alongside custom properties | Yes |
| Sync token returns only changed objects | Yes |
| Raw JSON in a custom property | Truncated at first comma by Radicale |
| Base64 JSON in a custom property | Round-trips |

## What has not been tested

These are the main risks. Stalwart with app passwords is the agreed target for
the next round.

1. **Stalwart.** Nothing has been run against it. Sync tokens, `VTODO`
   support and handling of custom properties all need confirming.
2. **Apple Reminders editing a calcify task.** Whether calcify's properties
   survive an edit or a completion from the phone.
3. **Apple Reminders completing a repeating task.** Clients differ here. If
   Reminders records the completion as a per-occurrence override instead of
   marking the task completed, the roll-forward trigger above will not see it
   and needs a second case.
4. **A rule on a task another client rolls forward.** If the other client
   advances the due date without ever writing `STATUS:COMPLETED`, calcify
   cannot tell the task was completed, and the rule does not fire. Under the
   tenets this is acceptable, but it should be a known limitation, not a
   surprise.
5. **Clients deleting old completed tasks.** Whether any common client or
   server purges completed tasks after a period. This decides where
   completion history lives.

## Open questions

1. **Roll-forward mechanics.** The sketch above is not settled and waits on
   client testing.
2. **Where history lives.** CalDAV is preferred; the fallback is calcify's
   database. Waits on the test for clients deleting old completed tasks.
3. **Sign-in details.** Password hashing, the OIDC library, session handling,
   and how the first account is created.
4. **Per-member CalDAV accounts.** One shared account is the decision for
   now and may be revisited.
