---
name: state-architect
description: Coordinate mock application data matrices (Kanban lanes, drag-and-drop reordering, multi-view lists) in a React frontend without fracturing UI state. Use when building or refactoring any feature where one dataset is rendered across several interactive containers and items move between them.
---

# State Architect

Goal: a single dataset drives every view, and moving an item never leaves two containers disagreeing about where it is.

The failure this skill prevents: duplicating a list per lane, then trying to keep the copies in sync. That works until the first drag, then diverges silently. Everything below follows from refusing to duplicate.

---

## Rule 1: One flat source of truth

Store entities in a flat, id-keyed map. Store membership and order as arrays of ids. Never nest the entity inside its container.

```js
// state shape
{
  cards:  { 'c1': {id:'c1', title:'…'}, 'c2': {…} },  // entities, flat
  lanes:  { 'todo': {id:'todo', name:'To Do', cardIds:['c1','c2']},
            'done': {id:'done', name:'Done',  cardIds:[]} },
  laneOrder: ['todo','done'],                          // order of the lanes themselves
}
```

A move is then two array splices on `cardIds` — the card object itself is never touched, copied, or re-created. If a task ever requires editing an entity to move it, the shape is wrong; fix the shape.

Derive everything else. Counts, filtered views, "cards assigned to me", per-lane totals — compute at render from the map. Never store a derived value in state; a stored derivation is a second source of truth waiting to drift.

## Rule 2: One reducer owns all mutations

Put every state transition in a single `useReducer` (or one store slice). No `useState` per lane, no per-column setter passed down. Components dispatch intent; the reducer decides.

```js
dispatch({ type:'MOVE_CARD', cardId, from:'todo', to:'done', toIndex:0 })
```

Actions name the user's intent (`MOVE_CARD`, `REORDER_LANE`), not the mechanical write (`SET_TODO_IDS`). Intent-named actions survive refactors of the state shape; write-named ones do not.

Cross-container moves are **one** action, not a remove-then-insert pair. Two dispatches means one render where the item exists in neither lane — that flicker is the fracture.

```js
case 'MOVE_CARD': {
  const { cardId, from, to, toIndex } = action
  const src = state.lanes[from].cardIds.filter(id => id !== cardId)
  // same-lane reorder: splice into the already-filtered array
  const dstBase = from === to ? src : state.lanes[to].cardIds
  const dst = [...dstBase.slice(0, toIndex), cardId, ...dstBase.slice(toIndex)]
  return { ...state, lanes: { ...state.lanes,
    [from]: { ...state.lanes[from], cardIds: from === to ? dst : src },
    [to]:   { ...state.lanes[to],   cardIds: dst } } }
}
```

Note the same-lane case: filtering before inserting is what stops an item from duplicating when dragged within its own lane. Handle it in the reducer, not by branching at the call site.

## Rule 3: Drag state is not app state

Keep the in-flight drag (`draggingId`, `overLaneId`, `overIndex`) in separate local state or a ref. It changes on every pointer move; putting it in the main reducer re-renders the whole board dozens of times per second.

Commit to the reducer **once**, on drop. On cancel or an invalid drop, discard the drag state and dispatch nothing — the board is already correct because you never mutated it.

Render the drop indicator from drag state, and the cards from app state. They are two independent reads; never try to render a "preview" by mutating the real array.

## Rule 4: Ids are stable and explicit

Generate ids at creation and never recompute them. Use `key={card.id}` — never `key={index}`. An index key makes React reuse the wrong DOM node after a reorder, which reads as "the drag moved the wrong card" and sends you debugging the reducer, which is fine.

If mock data is seeded at module scope, seed it once as a module constant. Re-generating ids inside a component body creates new ids on every render.

## Rule 5: Sequence for building the feature

Follow this order. Each step is verifiable before the next adds risk.

1. Define the state shape and the seed data. Log it; confirm the shape.
2. Write the reducer with every action, and exercise it as plain function calls — no UI.
3. Render read-only from state. Confirm all lanes and counts look right.
4. Add dispatch on a plain button ("move to next lane"). Confirm moves are correct.
5. Only now add drag-and-drop, wired to the same already-working action.

Adding drag before step 4 conflates two failure sources — a bad reducer and bad pointer handling look identical on screen.

---

## When it goes wrong

If an item duplicates or vanishes, do not patch the symptom in the component. Log the ids arrays before and after the action, and find which invariant broke:

- **Same id in two lanes** → the remove half of a move didn't run, or ran on a stale copy.
- **Id in no lane** → two dispatches instead of one, or the insert used a stale index.
- **Right data, wrong card animates** → index keys, not a state bug.
- **Counts disagree with the list** → a count is stored somewhere instead of derived.

Fix the invariant in the reducer. A guard in a component that hides the bad state is not a fix — it makes the next fracture harder to see.
