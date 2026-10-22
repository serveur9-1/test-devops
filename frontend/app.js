// Chemin relatif : Nginx redirige /api/ vers le backend FastAPI.
const API_URL = "/api";

const form = document.getElementById("task-form");
const input = document.getElementById("task-title");
const submitButton = form.querySelector("button[type=submit]");
const list = document.getElementById("task-list");
const message = document.getElementById("message");

function showMessage(text) {
  message.textContent = text;
}

function buildTaskItem(task) {
  const item = document.createElement("li");

  const title = document.createElement("span");
  title.className = "task-title";
  title.textContent = task.title; // textContent, et non innerHTML : évite les injections
  item.appendChild(title);

  const button = document.createElement("button");
  button.type = "button";
  button.className = "delete";
  button.textContent = "Supprimer";
  button.addEventListener("click", () => deleteTask(task.id, button));
  item.appendChild(button);

  return item;
}

function renderEmptyState() {
  // Un <ul> ne doit contenir que des <li>, d'où ce <li> plutôt qu'un <p>.
  const item = document.createElement("li");
  item.className = "empty";
  item.textContent = "Aucune tâche pour le moment.";
  list.appendChild(item);
}

async function loadTasks() {
  try {
    const response = await fetch(`${API_URL}/tasks`);
    if (!response.ok) {
      throw new Error("Chargement impossible");
    }

    const tasks = await response.json();
    list.innerHTML = "";

    if (tasks.length === 0) {
      renderEmptyState();
      return;
    }

    tasks.forEach((task) => list.appendChild(buildTaskItem(task)));
  } catch (error) {
    showMessage("Impossible de contacter l'API.");
  }
}

async function createTask(title) {
  const response = await fetch(`${API_URL}/tasks`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title }),
  });

  if (response.status === 422) {
    throw new Error("Titre invalide (1 à 200 caractères).");
  }
  if (!response.ok) {
    throw new Error("Ajout impossible.");
  }
}

async function deleteTask(taskId, button) {
  button.disabled = true;
  try {
    const response = await fetch(`${API_URL}/tasks/${taskId}`, {
      method: "DELETE",
    });
    if (!response.ok) {
      throw new Error("Suppression impossible");
    }
    showMessage("");
    await loadTasks();
  } catch (error) {
    button.disabled = false;
    showMessage("Suppression impossible.");
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();

  // Contrôle de confort uniquement : le backend revalide systématiquement.
  const title = input.value.trim();
  if (title === "") {
    showMessage("Le titre ne peut pas être vide.");
    return;
  }

  submitButton.disabled = true;
  try {
    await createTask(title);
    input.value = "";
    showMessage("");
    await loadTasks();
  } catch (error) {
    showMessage(error.message);
  } finally {
    submitButton.disabled = false;
    input.focus();
  }
});

loadTasks();
