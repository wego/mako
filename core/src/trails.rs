//! Trails: the tree of pages, as plain data.
//!
//! Everything here is pure: `apply(state, action)` returns a new state and never
//! touches the old one, the clock, or the disk. The whole state, including the
//! undo stack of closed pages, is one serde value, so the shell can save it after
//! any change and restore it at launch, and Undo Close survives a restart.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

pub type Id = u64;

pub const VERSION: u32 = 1;
pub const DEFAULT_MAX_TRAILS: usize = 3;
/// Closed subtrees kept for Undo Close.
pub const MAX_CLOSED: usize = 20;

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Trails {
    pub version: u32,
    /// Ids are never reused, so a closed page can come back without clashing.
    pub next_id: Id,
    /// Top-level pages (trailheads), in sidebar order.
    pub roots: Vec<Id>,
    pub nodes: BTreeMap<Id, Node>,
    pub active: Option<Id>,
    /// Most recently closed last.
    pub closed: Vec<Closed>,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Node {
    pub id: Id,
    pub parent: Option<Id>,
    pub children: Vec<Id>,
    pub url: String,
    pub title: String,
    /// User-given name; shown instead of the page title.
    pub name: Option<String>,
    pub collapsed: bool,
}

/// A closed subtree, enough to put it back where it was.
#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
pub struct Closed {
    /// The subtree's nodes; the first is its root.
    pub nodes: Vec<Node>,
    /// Position among its siblings (or among the roots) when closed.
    pub index: usize,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Debug)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Action {
    /// Start a new trail (a top-level page).
    OpenTrail { url: String },
    /// A link followed from `parent`: the new page goes beneath it, last.
    /// `select: false` leaves the current page active (a link opened in the background).
    OpenChild { parent: Id, url: String, #[serde(default = "yes")] select: bool },
    /// The page in this node changed address or title in place (redirect, in-page navigation).
    Navigated { id: Id, url: String, title: String },
    Select { id: Id },
    /// Close a page and everything beneath it.
    Close { id: Id },
    /// Reopen the most recently closed page, with its subtree, where it was.
    UndoClose,
    SetCollapsed { id: Id, collapsed: bool },
    Rename { id: Id, name: Option<String> },
    /// Move a page, with everything beneath it, next to or inside another page (drag and drop).
    Place { id: Id, target: Id, place: Place },
    /// Move a page one step: among its siblings, under the page above, or out beside its parent.
    Nudge { id: Id, direction: Direction },
}

fn yes() -> bool { true }

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Place { Before, After, Inside }

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
pub enum Direction { Up, Down, In, Out }

#[derive(Clone, PartialEq, Debug)]
pub enum Error {
    NoSuchPage(Id),
    TrailCap(usize),
    NothingToUndo,
    IntoItself,
    Invalid(String),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Error::NoSuchPage(id) => write!(f, "no page {id}"),
            Error::TrailCap(max) => write!(f, "trail cap reached ({max})"),
            Error::NothingToUndo => write!(f, "nothing to undo"),
            Error::IntoItself => write!(f, "a page cannot move into itself"),
            Error::Invalid(why) => write!(f, "invalid trails state: {why}"),
        }
    }
}

/// One visible sidebar row.
#[derive(Serialize, Clone, PartialEq, Debug)]
pub struct Row {
    pub id: Id,
    pub depth: usize,
    pub label: String,
    pub url: String,
    pub title: String,
    pub active: bool,
    pub collapsed: bool,
    pub has_children: bool,
}

impl Default for Trails {
    fn default() -> Self {
        Trails { version: VERSION, next_id: 1, roots: vec![], nodes: BTreeMap::new(), active: None, closed: vec![] }
    }
}

/// The only way state changes. On error the caller keeps the state it had.
pub fn apply(state: &Trails, action: &Action, max_trails: usize) -> Result<Trails, Error> {
    let mut s = state.clone();
    let has = |s: &Trails, id: Id| if s.nodes.contains_key(&id) { Ok(()) } else { Err(Error::NoSuchPage(id)) };
    match action {
        Action::OpenTrail { url } => {
            if s.roots.len() >= max_trails {
                return Err(Error::TrailCap(max_trails));
            }
            let id = add(&mut s, None, url);
            s.roots.push(id);
        }
        Action::OpenChild { parent, url, select } => {
            has(&s, *parent)?;
            let was_active = s.active;
            let id = add(&mut s, Some(*parent), url);
            s.nodes.get_mut(parent).unwrap().children.push(id);
            if *select {
                reveal(&mut s, id);
            } else {
                s.active = was_active;
            }
        }
        Action::Navigated { id, url, title } => {
            let n = s.nodes.get_mut(id).ok_or(Error::NoSuchPage(*id))?;
            n.url = url.clone();
            n.title = title.clone();
        }
        Action::Select { id } => {
            has(&s, *id)?;
            s.active = Some(*id);
            reveal(&mut s, *id);
        }
        Action::Close { id } => {
            has(&s, *id)?;
            let parent = s.nodes[id].parent;
            let ids = subtree(&s, *id);
            let siblings = siblings_mut(&mut s, parent);
            let index = siblings.iter().position(|c| c == id).unwrap();
            siblings.remove(index);
            let neighbour = siblings.get(index).or(index.checked_sub(1).and_then(|i| siblings.get(i))).copied().or(parent);
            if s.active.is_some_and(|a| ids.contains(&a)) {
                s.active = neighbour;
            }
            let nodes = ids.iter().map(|i| s.nodes.remove(i).unwrap()).collect();
            s.closed.push(Closed { nodes, index });
            let extra = s.closed.len().saturating_sub(MAX_CLOSED);
            s.closed.drain(..extra);
        }
        Action::UndoClose => {
            let Closed { mut nodes, index } = s.closed.pop().ok_or(Error::NothingToUndo)?;
            let root = nodes[0].id;
            // Its parent may have been closed since; then it comes back as a trail of its own.
            let parent = nodes[0].parent.filter(|p| s.nodes.contains_key(p));
            if parent.is_none() && s.roots.len() >= max_trails {
                return Err(Error::TrailCap(max_trails));
            }
            nodes[0].parent = parent;
            s.nodes.extend(nodes.into_iter().map(|n| (n.id, n)));
            let siblings = siblings_mut(&mut s, parent);
            siblings.insert(index.min(siblings.len()), root);
            s.active = Some(root);
            reveal(&mut s, root);
        }
        Action::SetCollapsed { id, collapsed } => {
            s.nodes.get_mut(id).ok_or(Error::NoSuchPage(*id))?.collapsed = *collapsed;
            // The active page must stay visible: collapsing above it moves to the collapsed page.
            if *collapsed && s.active.is_some_and(|a| a != *id && subtree(&s, *id).contains(&a)) {
                s.active = Some(*id);
            }
        }
        Action::Place { id, target, place } => {
            has(&s, *id)?;
            has(&s, *target)?;
            if subtree(&s, *id).contains(target) {
                return Err(Error::IntoItself);
            }
            let parent = if *place == Place::Inside { Some(*target) } else { s.nodes[target].parent };
            relocate(&mut s, *id, parent, max_trails, |siblings| match place {
                Place::Inside => siblings.len(),
                _ => siblings.iter().position(|c| c == target).unwrap() + usize::from(*place == Place::After),
            })?;
        }
        Action::Nudge { id, direction } => {
            has(&s, *id)?;
            let parent = s.nodes[id].parent;
            let siblings = siblings_mut(&mut s, parent).clone();
            let at = siblings.iter().position(|c| c == id).unwrap();
            match direction {
                Direction::Up if at > 0 => relocate(&mut s, *id, parent, max_trails, |_| at - 1)?,
                Direction::Down if at + 1 < siblings.len() => relocate(&mut s, *id, parent, max_trails, |_| at + 1)?,
                Direction::In if at > 0 => relocate(&mut s, *id, Some(siblings[at - 1]), max_trails, |c| c.len())?,
                Direction::Out => {
                    if let Some(p) = parent {
                        let grandparent = s.nodes[&p].parent;
                        relocate(&mut s, *id, grandparent, max_trails, |c| c.iter().position(|x| *x == p).unwrap() + 1)?;
                    }
                }
                _ => {} // already at the edge: nothing to do
            }
        }
        Action::Rename { id, name } => {
            s.nodes.get_mut(id).ok_or(Error::NoSuchPage(*id))?.name = name.clone().filter(|n| !n.trim().is_empty());
        }
    }
    Ok(s)
}

fn add(s: &mut Trails, parent: Option<Id>, url: &str) -> Id {
    let id = s.next_id;
    s.next_id += 1;
    s.nodes.insert(id, Node { id, parent, children: vec![], url: url.into(), title: String::new(), name: None, collapsed: false });
    s.active = Some(id);
    id
}

/// Moves `id`, with its subtree, under `parent` (None = a trail of its own) at the index
/// `at` picks from the new siblings once `id` has left its old place.
fn relocate(s: &mut Trails, id: Id, parent: Option<Id>, max_trails: usize, at: impl FnOnce(&Vec<Id>) -> usize) -> Result<(), Error> {
    let old = s.nodes[&id].parent;
    if parent.is_none() && old.is_some() && s.roots.len() >= max_trails {
        return Err(Error::TrailCap(max_trails));
    }
    siblings_mut(s, old).retain(|c| *c != id);
    let siblings = siblings_mut(s, parent);
    let index = at(siblings).min(siblings.len());
    siblings.insert(index, id);
    s.nodes.get_mut(&id).unwrap().parent = parent;
    // Keep the active page visible wherever it ended up.
    if let Some(active) = s.active {
        reveal(s, active);
    }
    Ok(())
}

/// Expands every page above `id` so its row is visible.
fn reveal(s: &mut Trails, id: Id) {
    let mut up = s.nodes[&id].parent;
    while let Some(p) = up {
        let n = s.nodes.get_mut(&p).unwrap();
        n.collapsed = false;
        up = n.parent;
    }
}

fn siblings_mut(s: &mut Trails, parent: Option<Id>) -> &mut Vec<Id> {
    match parent {
        Some(p) => &mut s.nodes.get_mut(&p).unwrap().children,
        None => &mut s.roots,
    }
}

/// `id` and everything beneath it, parents before children.
fn subtree(s: &Trails, id: Id) -> Vec<Id> {
    let mut out = vec![id];
    let mut i = 0;
    while i < out.len() {
        out.extend(&s.nodes[&out[i]].children);
        i += 1;
    }
    out
}

/// Sidebar rows in display order; children of collapsed pages are left out.
pub fn rows(state: &Trails) -> Vec<Row> {
    fn walk(s: &Trails, id: Id, depth: usize, out: &mut Vec<Row>) {
        let n = &s.nodes[&id];
        let label = n.name.as_deref().or(Some(n.title.as_str()).filter(|t| !t.is_empty())).unwrap_or(&n.url);
        out.push(Row {
            id, depth, label: label.into(), url: n.url.clone(), title: n.title.clone(), active: s.active == Some(id),
            collapsed: n.collapsed, has_children: !n.children.is_empty(),
        });
        if !n.collapsed {
            n.children.iter().for_each(|c| walk(s, *c, depth + 1, out));
        }
    }
    let mut out = vec![];
    state.roots.iter().for_each(|r| walk(state, *r, 0, &mut out));
    out
}

/// Parses saved state and checks it is a well-formed tree before anything trusts it.
pub fn load(json: &str) -> Result<Trails, Error> {
    let s: Trails = serde_json::from_str(json).map_err(|e| Error::Invalid(e.to_string()))?;
    let bad = |why: &str| Err(Error::Invalid(why.into()));
    if s.version != VERSION {
        return bad(&format!("version {} (this build reads {VERSION})", s.version));
    }
    // Every node must be reached exactly once from the roots, through a parent that agrees.
    let mut seen = BTreeSet::new();
    let mut stack: Vec<(Id, Option<Id>)> = s.roots.iter().map(|r| (*r, None)).collect();
    while let Some((id, parent)) = stack.pop() {
        let Some(n) = s.nodes.get(&id) else { return bad(&format!("page {id} is missing")) };
        if n.id != id || n.parent != parent {
            return bad(&format!("page {id} disagrees with its parent"));
        }
        if !seen.insert(id) {
            return bad(&format!("page {id} appears twice"));
        }
        stack.extend(n.children.iter().map(|c| (*c, Some(id))));
    }
    if seen.len() != s.nodes.len() {
        return bad("pages not attached to any trail");
    }
    if s.active.is_some_and(|a| !seen.contains(&a)) {
        return bad("active page is missing");
    }
    let closed_ids = s.closed.iter().flat_map(|c| c.nodes.iter().map(|n| n.id));
    if seen.iter().copied().chain(closed_ids).any(|id| id >= s.next_id) {
        return bad("next_id would reuse an id");
    }
    if s.closed.iter().any(|c| c.nodes.is_empty()) {
        return bad("empty closed entry");
    }
    Ok(s)
}

pub fn save(state: &Trails) -> String {
    serde_json::to_string(state).expect("trails state is plain data")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(state: &Trails, actions: &[Action]) -> Trails {
        actions.iter().fold(state.clone(), |s, a| apply(&s, a, DEFAULT_MAX_TRAILS).unwrap())
    }
    fn trail(url: &str) -> Action { Action::OpenTrail { url: url.into() } }
    fn child(parent: Id, url: &str) -> Action { Action::OpenChild { parent, url: url.into(), select: true } }
    fn shape(s: &Trails) -> Vec<(usize, String)> { rows(s).into_iter().map(|r| (r.depth, r.url)).collect() }

    /// a(1) > [b(2) > [d(4)], c(3)], e(5)
    fn sample() -> Trails {
        run(&Trails::default(), &[trail("a"), child(1, "b"), child(1, "c"), child(2, "d"), trail("e")])
    }

    #[test]
    fn links_nest_beneath_their_page_in_travel_order() {
        let s = sample();
        assert_eq!(shape(&s), [(0, "a".into()), (1, "b".into()), (2, "d".into()), (1, "c".into()), (0, "e".into())]);
        assert_eq!(s.active, Some(5));
        assert_eq!(s.nodes[&4].parent, Some(2));
    }

    #[test]
    fn apply_never_changes_the_state_it_was_given() {
        let before = sample();
        let copy = before.clone();
        apply(&before, &Action::Close { id: 2 }, 2).unwrap();
        apply(&before, &trail("x"), 2).unwrap_err();
        assert_eq!(before, copy);
    }

    #[test]
    fn trails_are_capped_but_pages_within_them_are_not() {
        let s = sample();
        assert_eq!(apply(&s, &trail("f"), 2), Err(Error::TrailCap(2)));
        assert!(apply(&s, &trail("f"), 3).is_ok());
        let deep = (0..50).fold(s, |s, _| apply(&s, &child(s.active.unwrap(), "p"), 2).unwrap());
        assert_eq!(deep.nodes.len(), 55);
    }

    #[test]
    fn close_removes_the_subtree_and_moves_to_a_neighbour() {
        let s = run(&sample(), &[Action::Select { id: 4 }, Action::Close { id: 2 }]);
        assert_eq!(shape(&s), [(0, "a".into()), (1, "c".into()), (0, "e".into())]);
        assert_eq!(s.active, Some(3), "next sibling takes over");
        let s = run(&s, &[Action::Close { id: 3 }]);
        assert_eq!(s.active, Some(1), "no sibling left: the parent");
        let s = run(&s, &[Action::Close { id: 1 }]);
        assert_eq!(s.active, Some(5), "a closed trail hands over to the other trail");
        let s = run(&s, &[Action::Close { id: 5 }]);
        assert_eq!((s.active, s.nodes.len()), (None, 0));
    }

    #[test]
    fn closing_an_inactive_page_keeps_the_active_one() {
        let s = run(&sample(), &[Action::Close { id: 2 }]);
        assert_eq!(s.active, Some(5));
    }

    #[test]
    fn undo_close_puts_the_subtree_back_exactly() {
        let before = run(&sample(), &[Action::Select { id: 2 }]);
        let after = run(&before, &[Action::Close { id: 2 }, Action::UndoClose]);
        assert_eq!(after, before);
    }

    #[test]
    fn undo_close_is_a_stack_and_survives_save_and_load() {
        let s = run(&sample(), &[Action::Close { id: 4 }, Action::Close { id: 3 }]);
        let restored = load(&save(&s)).unwrap();
        assert_eq!(restored, s);
        let s = run(&restored, &[Action::UndoClose]);
        assert_eq!(shape(&s), [(0, "a".into()), (1, "b".into()), (1, "c".into()), (0, "e".into())]);
        let s = run(&s, &[Action::UndoClose]);
        assert_eq!(shape(&s), shape(&sample()));
        assert_eq!(apply(&s, &Action::UndoClose, 2), Err(Error::NothingToUndo));
    }

    #[test]
    fn undo_close_whose_parent_is_gone_comes_back_as_a_trail_if_there_is_room() {
        // close d, then its ancestor trail a: undoing twice restores a first, then d under b.
        let s = run(&sample(), &[Action::Close { id: 4 }, Action::Close { id: 1 }]);
        let s = run(&s, &[Action::UndoClose, Action::UndoClose]);
        assert_eq!(shape(&s), shape(&sample()));
        // close d, close trail a, then drop a from the undo stack by reopening and re-closing differently:
        let s = run(&sample(), &[Action::Close { id: 1 }, Action::Close { id: 5 }, trail("x"), trail("y")]);
        assert_eq!(apply(&s, &Action::UndoClose, 2), Err(Error::TrailCap(2)), "both trail slots taken");
        assert_eq!(apply(&s, &Action::UndoClose, 3).unwrap().roots.len(), 3);
    }

    #[test]
    fn closed_stack_is_bounded() {
        let mut s = run(&Trails::default(), &[trail("a")]);
        for _ in 0..MAX_CLOSED + 5 {
            s = run(&s, &[child(1, "p")]);
            s = run(&s, &[Action::Close { id: s.active.unwrap() }]);
        }
        assert_eq!(s.closed.len(), MAX_CLOSED);
    }

    #[test]
    fn collapse_hides_children_and_opening_a_child_expands() {
        let s = run(&sample(), &[Action::SetCollapsed { id: 1, collapsed: true }]);
        assert_eq!(shape(&s), [(0, "a".into()), (0, "e".into())]);
        assert!(rows(&s)[0].collapsed && rows(&s)[0].has_children);
        let s = run(&s, &[child(1, "z")]);
        assert_eq!(shape(&s).len(), 6);
    }

    #[test]
    fn the_active_page_is_always_a_visible_row() {
        let visible = |s: &Trails| rows(s).iter().any(|r| r.active);
        // collapsing above the active page moves to the collapsed page
        let s = run(&sample(), &[Action::Select { id: 4 }, Action::SetCollapsed { id: 1, collapsed: true }]);
        assert_eq!(s.active, Some(1));
        // selecting, or reopening, a page inside collapsed pages expands the way to it
        let s = run(&s, &[Action::Select { id: 4 }]);
        assert!(visible(&s) && !s.nodes[&1].collapsed && !s.nodes[&2].collapsed);
        let s = run(&s, &[Action::Close { id: 4 }, Action::SetCollapsed { id: 1, collapsed: true }, Action::UndoClose]);
        assert!(visible(&s) && s.active == Some(4));
        // collapsing elsewhere leaves the active page alone
        let s = run(&sample(), &[Action::SetCollapsed { id: 1, collapsed: true }]);
        assert_eq!(s.active, Some(5));
    }

    #[test]
    fn navigated_and_rename_change_the_label_not_the_shape() {
        let s = run(&sample(), &[Action::Navigated { id: 3, url: "c2".into(), title: "See".into() }]);
        let row = rows(&s).into_iter().find(|r| r.id == 3).unwrap();
        assert_eq!((row.label.as_str(), row.url.as_str(), row.title.as_str()), ("See", "c2", "See"));
        let s = run(&s, &[Action::Rename { id: 3, name: Some("Mine".into()) }]);
        assert_eq!(rows(&s).into_iter().find(|r| r.id == 3).unwrap().label, "Mine");
        let s = run(&s, &[Action::Rename { id: 3, name: None }]);
        assert_eq!(rows(&s).into_iter().find(|r| r.id == 3).unwrap().label, "See");
        assert_eq!(rows(&sample())[0].label, "a", "no title yet: the address");
    }

    fn place(id: Id, target: Id, place: Place) -> Action { Action::Place { id, target, place } }
    fn nudge(id: Id, direction: Direction) -> Action { Action::Nudge { id, direction } }

    #[test]
    fn a_page_can_be_dropped_before_after_or_inside_another() {
        // sample: a(1) > [b(2) > [d(4)], c(3)], e(5)
        let s = run(&sample(), &[place(3, 2, Place::Before)]);
        assert_eq!(shape(&s), [(0, "a".into()), (1, "c".into()), (1, "b".into()), (2, "d".into()), (0, "e".into())]);
        let s = run(&sample(), &[place(2, 3, Place::After)]);
        assert_eq!(shape(&s), [(0, "a".into()), (1, "c".into()), (1, "b".into()), (2, "d".into()), (0, "e".into())], "subtree moves along");
        let s = run(&sample(), &[place(2, 5, Place::Inside)]);
        assert_eq!(shape(&s), [(0, "a".into()), (1, "c".into()), (0, "e".into()), (1, "b".into()), (2, "d".into())]);
        assert_eq!(s.nodes[&2].parent, Some(5));
        // a whole trail can become a page of another trail, freeing a trail slot
        let s = run(&sample(), &[place(5, 4, Place::Inside)]);
        assert_eq!((s.roots.clone(), s.nodes[&5].parent), (vec![1], Some(4)));
        assert_eq!(load(&save(&s)).unwrap(), s, "still a well-formed tree");
    }

    #[test]
    fn moves_that_would_break_the_tree_are_refused() {
        let s = sample();
        assert_eq!(apply(&s, &place(1, 4, Place::Inside), 2), Err(Error::IntoItself), "under its own descendant");
        assert_eq!(apply(&s, &place(2, 2, Place::Before), 2), Err(Error::IntoItself));
        assert_eq!(apply(&s, &place(3, 5, Place::Before), 2), Err(Error::TrailCap(2)), "a third trail");
        assert!(apply(&s, &place(5, 1, Place::Before), 2).is_ok(), "reordering trails is not a new trail");
        assert_eq!(apply(&s, &place(9, 1, Place::Inside), 2), Err(Error::NoSuchPage(9)));
        assert_eq!(apply(&s, &place(1, 9, Place::Inside), 2), Err(Error::NoSuchPage(9)));
    }

    #[test]
    fn moving_into_a_collapsed_page_keeps_the_active_page_visible() {
        let s = run(&sample(), &[Action::SetCollapsed { id: 5, collapsed: true }, Action::Select { id: 4 }, place(4, 5, Place::Inside)]);
        assert!(rows(&s).iter().any(|r| r.active) && !s.nodes[&5].collapsed);
    }

    #[test]
    fn nudge_reorders_indents_and_outdents() {
        // a(1) > [b(2) > [d(4)], c(3)], e(5)
        let s = run(&sample(), &[nudge(3, Direction::Up)]);
        assert_eq!(s.nodes[&1].children, [3, 2]);
        let s = run(&s, &[nudge(3, Direction::Down)]);
        assert_eq!(s, sample_with_active(&s));
        assert_eq!(run(&sample(), &[nudge(3, Direction::Down)]).nodes[&1].children, [2, 3], "already last: unchanged");
        let s = run(&sample(), &[nudge(3, Direction::In)]);
        assert_eq!(s.nodes[&2].children, [4, 3], "indent: last child of the page above");
        assert_eq!(run(&sample(), &[nudge(2, Direction::In)]).nodes[&1].children, [2, 3], "no page above: unchanged");
        let s = run(&sample(), &[nudge(4, Direction::Out)]);
        assert_eq!(s.nodes[&1].children, [2, 4, 3], "outdent: right after its old parent");
        assert_eq!(apply(&sample(), &nudge(2, Direction::Out), 2), Err(Error::TrailCap(2)), "outdent to a third trail");
        assert_eq!(run(&sample(), &[nudge(5, Direction::Up)]).roots, [5, 1], "trails reorder too");
    }
    fn sample_with_active(s: &Trails) -> Trails { Trails { active: s.active, ..sample() } }

    #[test]
    fn a_link_can_open_in_the_background() {
        let s = run(&sample(), &[Action::Select { id: 1 }, Action::OpenChild { parent: 1, url: "bg".into(), select: false }]);
        assert_eq!((s.active, s.nodes[&1].children.last().copied()), (Some(1), Some(6)));
        let a: Action = serde_json::from_str(r#"{"type":"open_child","parent":1,"url":"u","select":false}"#).unwrap();
        assert_eq!(a, Action::OpenChild { parent: 1, url: "u".into(), select: false });
    }

    #[test]
    fn unknown_pages_are_errors() {
        let s = sample();
        for a in [child(9, "x"), Action::Select { id: 9 }, Action::Close { id: 9 },
                  Action::Navigated { id: 9, url: "u".into(), title: "t".into() },
                  Action::SetCollapsed { id: 9, collapsed: true }, Action::Rename { id: 9, name: None }] {
            assert_eq!(apply(&s, &a, 2), Err(Error::NoSuchPage(9)), "{a:?}");
        }
    }

    #[test]
    fn load_rejects_malformed_state() {
        let good = sample();
        assert_eq!(load(&save(&good)).unwrap(), good);
        assert!(matches!(load("not json"), Err(Error::Invalid(_))));
        let bad = |f: &dyn Fn(&mut Trails)| { let mut s = good.clone(); f(&mut s); load(&save(&s)) };
        assert!(bad(&|s| s.version = 99).is_err(), "unknown version");
        assert!(bad(&|s| s.active = Some(77)).is_err(), "active page missing");
        assert!(bad(&|s| s.roots.push(77)).is_err(), "root missing");
        assert!(bad(&|s| s.nodes.get_mut(&4).unwrap().parent = Some(3)).is_err(), "parent/children disagree");
        assert!(bad(&|s| s.nodes.get_mut(&2).unwrap().children.push(1)).is_err(), "cycle");
        assert!(bad(&|s| s.next_id = 2).is_err(), "next_id would reuse an id");
        assert!(bad(&|s| { s.nodes.get_mut(&1).unwrap().children.retain(|c| *c != 3); }).is_err(), "orphan");
    }

    #[test]
    fn actions_have_a_stable_json_form() {
        let a: Action = serde_json::from_str(r#"{"type":"open_child","parent":1,"url":"https://a.test/"}"#).unwrap();
        assert_eq!(a, child(1, "https://a.test/"));
        assert_eq!(serde_json::to_string(&Action::UndoClose).unwrap(), r#"{"type":"undo_close"}"#);
    }
}
