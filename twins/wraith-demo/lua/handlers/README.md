# Lua handlers

Drop one file per handler here. Handlers bind to routes **by filename** — no
config edit needed. Restart `wraith serve` to pick up new or changed files.

## Naming convention

Files are `<verb>_<entity>.lua`, snake_case, where `<entity>` is the route's
collection name (singularized for create/read/update/delete, plural for list):

| Operation | Example route                | Handler file                |
|-----------|------------------------------|-----------------------------|
| Create    | `POST /v1/orders`            | `create_order.lua`          |
| Read      | `GET /v1/orders/:id`         | `get_order.lua`             |
| Update    | `PATCH /v1/orders/:id`       | `update_order.lua`          |
| Delete    | `DELETE /v1/orders/:id`      | `delete_order.lua`          |
| List      | `GET /v1/orders`             | `list_orders.lua`           |
| Sub-route | `GET /v1/orders/:id/invoice` | `get_invoice.lua`           |

Accepted verbs:

- Create: `create_`, `add_`, `new_`, `post_`
- Read:   `get_`, `read_`, `show_`, `fetch_`
- Update: `update_`, `patch_`, `edit_`, `put_`
- Delete: `delete_`, `remove_`, `destroy_`
- List:   `list_`, `index_`, or the bare collection name (`orders.lua`)

Hyphenated, dotted, and camelCase entities are normalized to snake_case, so
`GET /v3/license-agreements/:id` binds to `get_license_agreement.lua` and
`GET /v1/lineItems/:id` binds to `get_line_item.lua`. Always name the file in
snake_case.

First match wins. Routes with no matching file fall through to the synth
template (silently — most routes don't need a handler).

The binding is re-synth-safe: it's derived from the route every time, never
stored in the model, so re-synthing the twin never drops your handlers.
