(() => {
  const STORAGE_KEY = "todos";

  function loadTodos() {
    try {
      return JSON.parse(localStorage.getItem(STORAGE_KEY)) || [];
    } catch {
      return [];
    }
  }

  function saveTodos(todos) {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(todos));
  }

  let todos = loadTodos();
  let currentFilter = "all";

  const form = document.getElementById("todo-form");
  const input = document.getElementById("todo-input");
  const list = document.getElementById("todo-list");
  const count = document.getElementById("count");
  const clearBtn = document.getElementById("clear-completed");
  const filterBtns = document.querySelectorAll(".filter");

  function render() {
    const filtered = todos.filter((t) => {
      if (currentFilter === "active") return !t.completed;
      if (currentFilter === "completed") return t.completed;
      return true;
    });

    list.innerHTML = "";
    filtered.forEach((todo) => {
      const li = document.createElement("li");
      if (todo.completed) li.classList.add("completed");

      const checkbox = document.createElement("input");
      checkbox.type = "checkbox";
      checkbox.checked = todo.completed;
      checkbox.addEventListener("change", () => toggle(todo.id));

      const text = document.createElement("span");
      text.className = "text";
      text.textContent = todo.text;

      const del = document.createElement("button");
      del.className = "delete";
      del.textContent = "\u00d7";
      del.addEventListener("click", () => remove(todo.id));

      li.append(checkbox, text, del);
      list.appendChild(li);
    });

    const active = todos.filter((t) => !t.completed).length;
    count.textContent = `${active} item${active !== 1 ? "s" : ""} left`;

    clearBtn.style.display = todos.some((t) => t.completed) ? "" : "none";
  }

  function addTodo(text) {
    todos.push({ id: Date.now(), text, completed: false });
    saveTodos(todos);
    render();
  }

  function toggle(id) {
    const todo = todos.find((t) => t.id === id);
    if (todo) todo.completed = !todo.completed;
    saveTodos(todos);
    render();
  }

  function remove(id) {
    todos = todos.filter((t) => t.id !== id);
    saveTodos(todos);
    render();
  }

  form.addEventListener("submit", (e) => {
    e.preventDefault();
    const text = input.value.trim();
    if (text) {
      addTodo(text);
      input.value = "";
    }
  });

  clearBtn.addEventListener("click", () => {
    todos = todos.filter((t) => !t.completed);
    saveTodos(todos);
    render();
  });

  filterBtns.forEach((btn) => {
    btn.addEventListener("click", () => {
      currentFilter = btn.dataset.filter;
      filterBtns.forEach((b) => b.classList.remove("active"));
      btn.classList.add("active");
      render();
    });
  });

  render();
})();
