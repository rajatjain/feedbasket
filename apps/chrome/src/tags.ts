const normalize = (name: string) => name.trim().toLowerCase();
const recentLimit = 3;

export function tagPicker() {
  const input = document.querySelector<HTMLInputElement>("#tags")!;
  const editor = document.getElementById("tag-editor")!;
  const selected = document.getElementById("selected-tags")!;
  const panel = document.getElementById("tag-suggestions")!;
  const heading = document.getElementById("tag-heading")!;
  const list = document.getElementById("suggested-tags")!;
  const feedback = document.getElementById("tag-feedback")!;
  const picked = new Map<string, string>();
  let tags = new Map<string, string>();
  let recent: string[] = [];
  let open = false;
  let active = 0;

  function notify(message: string) {
    feedback.textContent = message;
    feedback.hidden = !message;
  }

  function pick(names: string[]): boolean {
    const additions = new Map(names.map(name => {
      const key = normalize(name);
      return [key, tags.get(key) ?? key];
    }));
    const unique = [...additions].filter(([key]) => key && !picked.has(key));
    if (picked.size + unique.length > 30 || unique.some(([, name]) => Array.from(name).length > 80)) {
      notify("Use up to 30 tags of at most 80 characters.");
      return false;
    }
    for (const [key, name] of unique) picked.set(key, name);
    notify("");
    return true;
  }

  function renderSelected() {
    selected.replaceChildren();
    for (const [key, name] of picked) {
      const chip = document.createElement("button");
      chip.type = "button";
      chip.textContent = `${name} ×`;
      chip.setAttribute("aria-label", `Remove ${name}`);
      chip.addEventListener("click", () => {
        picked.delete(key);
        notify("");
        renderSelected();
        input.focus();
        renderSuggestions();
      });
      selected.append(chip);
    }
    selected.hidden = picked.size === 0;
  }

  function renderSuggestions() {
    const query = normalize(input.value);
    const byName = (a: string, b: string) => a.localeCompare(b);
    const available = [...tags.keys()].filter(key => !picked.has(key));
    let keys: string[] = [];
    if (query) {
      keys = available.filter(key => key.includes(query)).sort((a, b) =>
        Number(b.startsWith(query)) - Number(a.startsWith(query)) || byName(a, b));
    } else {
      keys = recent.filter(key => !picked.has(key)).slice(0, recentLimit);
      if (!keys.length) keys = available.slice(0, recentLimit);
    }
    const create = query && !query.includes(",") && !tags.has(query) && !picked.has(query);
    const options = keys.map(key => ({ name: tags.get(key) ?? key, create: false }));
    if (create) options.push({ name: input.value.trim(), create: true });
    panel.hidden = !open || options.length === 0;
    input.setAttribute("aria-expanded", String(!panel.hidden));
    input.removeAttribute("aria-activedescendant");
    if (panel.hidden) {
      list.replaceChildren();
      return;
    }
    heading.hidden = Boolean(query);
    heading.textContent = keys.some(key => recent.includes(key)) ? "Recent" : "Your tags";
    active = Math.min(active, options.length - 1);
    list.replaceChildren(...options.map(({ name, create }, index) => {
      const row = document.createElement("li");
      row.id = `tag-option-${index}`;
      row.setAttribute("role", "option");
      row.setAttribute("aria-selected", String(index === active));
      row.textContent = create ? `+  Create “${name}”` : name;
      row.dataset.name = name;
      if (create) row.className = "create-tag";
      return row;
    }));
    input.setAttribute("aria-activedescendant", list.children[active].id);
  }

  function close() {
    open = false;
    input.setAttribute("aria-expanded", "false");
    input.removeAttribute("aria-activedescendant");
    panel.hidden = true;
  }

  function commit(names: string[]): boolean {
    if (!pick(names)) return false;
    input.value = "";
    active = 0;
    renderSelected();
    renderSuggestions();
    return true;
  }

  input.addEventListener("focus", () => {
    open = true;
    active = 0;
    renderSuggestions();
  });
  input.addEventListener("click", () => {
    if (open) return;
    open = true;
    active = 0;
    renderSuggestions();
  });
  input.addEventListener("input", () => {
    open = true;
    active = 0;
    notify("");
    renderSuggestions();
  });
  input.addEventListener("focusout", close);
  list.addEventListener("mousedown", event => event.preventDefault());
  list.addEventListener("click", event => {
    const row = (event.target as HTMLElement).closest<HTMLElement>("[role=option]");
    if (row?.dataset.name) commit([row.dataset.name]);
  });
  input.addEventListener("keydown", event => {
    if (event.isComposing) return;
    if (event.key === "Escape" && open) {
      event.preventDefault();
      close();
    } else if (event.key === "Enter") {
      event.preventDefault();
      const option = panel.hidden ? undefined : (list.children[active] as HTMLElement | undefined)?.dataset.name;
      if (option) commit([option]);
      else commit(input.value.split(","));
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      if (!open || panel.hidden) {
        open = true;
        active = 0;
        renderSuggestions();
        return;
      }
      const count = list.children.length;
      list.children[active].setAttribute("aria-selected", "false");
      active = (active + (event.key === "ArrowDown" ? 1 : count - 1)) % count;
      const row = list.children[active];
      row.setAttribute("aria-selected", "true");
      input.setAttribute("aria-activedescendant", row.id);
      row.scrollIntoView({ block: "nearest" });
    }
  });
  editor.querySelector(".tag-entry")?.addEventListener("click", event => {
    if (!(event.target as HTMLElement).closest("button, input")) input.focus();
  });

  return {
    setTags(values: string[]) {
      tags = new Map(values.map(name => [normalize(name), name]));
      active = 0;
      renderSuggestions();
    },
    setRecent(values: string[]) {
      const keys = values.map(normalize);
      if (keys.join("\n") === recent.join("\n")) return;
      recent = keys;
      active = 0;
      renderSuggestions();
    },
    reset() {
      tags.clear();
      recent = [];
      picked.clear();
      input.value = "";
      close();
      notify("");
      renderSelected();
    },
    forSave() { return commit(input.value.split(",")) ? [...picked.values()] : null; },
    close,
  };
}
