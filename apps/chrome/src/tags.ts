type Tag = { name: string; count: number | null };

const normalize = (name: string) => name.trim().toLowerCase();
const featuredLimit = 5;

export function tagPicker() {
  const get = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
  const input = get<HTMLInputElement>("tags");
  const addButton = get<HTMLButtonElement>("add-tag");
  const selected = get("selected-tags");
  const suggestions = get("suggested-tags");
  const more = get<HTMLDetailsElement>("more-tags");
  const other = get("other-tags");
  const feedback = get("tag-feedback");
  const picked = new Map<string, string>();
  let tags: Tag[] = [];

  function notify(message: string) {
    feedback.textContent = message;
    feedback.hidden = !message;
  }

  function commitInput(): boolean {
    const names = input.value.split(",").map(name => name.trim()).filter(Boolean);
    if (!pick(names)) return false;
    input.value = "";
    render();
    return true;
  }

  function pick(names: string[]): boolean {
    const additions = new Set(names.map(normalize).filter(key => !picked.has(key)));
    if (picked.size + additions.size > 30 || [...additions].some(key => Array.from(key).length > 80)) {
      notify("Use up to 30 tags of at most 80 characters.");
      return false;
    }
    for (const key of additions) picked.set(key, tags.find(tag => normalize(tag.name) === key)?.name ?? key);
    notify("");
    return true;
  }

  function control(label: string, action: () => void) {
    const button = document.createElement("button");
    button.type = "button";
    button.textContent = label;
    button.addEventListener("click", action);
    return button;
  }

  function row(tag: Tag) {
    const key = normalize(tag.name);
    const checked = picked.has(key);
    const button = control("", () => {
      if (picked.delete(key)) notify("");
      else if (!pick([tag.name])) return;
      render();
      const target = Array.from(document.querySelectorAll<HTMLButtonElement>(".tag-list button[data-tag]"))
        .find(candidate => candidate.dataset.tag === key);
      (target ?? input).focus();
    });
    button.dataset.tag = key;
    button.setAttribute("aria-pressed", String(checked));
    const name = document.createElement("span");
    name.textContent = tag.name;
    const count = document.createElement("span");
    count.className = "tag-count";
    count.textContent = tag.count?.toLocaleString() ?? "";
    if (tag.count !== null) count.setAttribute("aria-label", `${tag.count} ${tag.count === 1 ? "article" : "articles"}`);
    const mark = document.createElement("span");
    mark.className = "tag-mark";
    mark.textContent = checked ? "✓" : "+";
    mark.setAttribute("aria-hidden", "true");
    button.append(name, count, mark);
    const item = document.createElement("li");
    item.append(button);
    return item;
  }

  function render() {
    selected.replaceChildren();
    for (const [key, name] of picked) {
      const chip = control(`${name} ×`, () => {
        picked.delete(key);
        notify("");
        render();
        input.focus();
      });
      chip.setAttribute("aria-label", `Remove ${name}`);
      selected.append(chip);
    }
    selected.hidden = picked.size === 0;

    const query = normalize(input.value);
    const hasOverflow = tags.length > featuredLimit;
    const matches = query ? tags.filter(tag => normalize(tag.name).includes(query)) : tags.slice(0, featuredLimit);
    const hasCounts = tags.some(tag => tag.count !== null);
    get("tag-heading").textContent = query ? "Matching tags" : hasOverflow && hasCounts ? "Most used tags" : "Your tags";
    get("tag-count-heading").hidden = !matches.some(tag => tag.count !== null);
    suggestions.replaceChildren(...matches.map(row));
    if (query && !query.includes(",") && !picked.has(query) && !matches.some(tag => normalize(tag.name) === query)) {
      const item = document.createElement("li");
      const create = control(`Create “${input.value.trim()}”`, () => {
        commitInput();
        input.focus();
      });
      create.className = "create-tag";
      item.append(create);
      suggestions.append(item);
    }
    get("tag-suggestions").hidden = !suggestions.childElementCount;

    more.hidden = Boolean(query) || !hasOverflow;
    if (!more.hidden) {
      const rest = tags.slice(featuredLimit).sort((a, b) => a.name.localeCompare(b.name));
      more.querySelector("summary")!.textContent = `More tags (${rest.length})`;
      other.replaceChildren(...rest.map(row));
    }
    addButton.disabled = !query;
  }

  input.addEventListener("input", () => { notify(""); render(); });
  input.addEventListener("keydown", event => {
    if (event.key === "Enter" && !event.isComposing) {
      event.preventDefault();
      commitInput();
    }
  });
  addButton.addEventListener("click", () => { commitInput(); input.focus(); });

  return {
    setTags(values: Tag[]) {
      tags = [...values].sort((a, b) => (b.count ?? 0) - (a.count ?? 0) || a.name.localeCompare(b.name));
      render();
    },
    reset() {
      tags = [];
      picked.clear();
      input.value = "";
      more.open = false;
      notify("");
      render();
    },
    forSave() { return commitInput() ? [...picked.values()] : null; },
  };
}
