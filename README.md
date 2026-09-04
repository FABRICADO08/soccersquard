# soccersquard
Adrian’s current app only administers the team members of each team. Each team has staff to manage and support the team. The staff members are just like a team member, a person, but have specific information which differs from a team member such as a coach certification and license number.
In this exercise, you will extend the app with staff members using inheritance so that both team members and staff can be handled equally, but with their specialized details

---

## Deploying with Docker & Render

This repository contains everything needed to build and run the Mendix app as a
Docker container:

- **`Dockerfile`** — builds the app using the official
  [Mendix Docker Buildpack](https://github.com/mendix/docker-mendix-buildpack).
  It compiles `SoccerSquad.mpr` and bundles the Mendix runtime, a JDK and nginx.
- **`render.yaml`** — a [Render Blueprint](https://render.com/docs/blueprint-spec)
  that deploys the Docker image as a web service on Render.
- **`.dockerignore`** — keeps the build context lean.
- **`.github/workflows/docker-build.yml`** — GitHub Actions workflow that builds
  and pushes the image to Docker Hub.

### Build & run locally

```bash
# Build the image (this compiles the Mendix model, so it can take 10-20 min)
docker build -t soccersquad .

# Run it (choose any admin password)
docker run -p 8080:8080 \
  -e ADMIN_PASSWORD='YourSecret1' \
  -e PORT=8080 \
  soccersquad
```

Then open http://localhost:8080 and log in as `MxAdmin` with the password you set.

### Deploy to Render

1. Push this repository to GitHub.
2. In Render, click **New → Blueprint** and connect this repository.
3. Render detects `render.yaml` and provisions the web service (and an optional
   PostgreSQL database).
4. When prompted, provide the secret value for `ADMIN_PASSWORD`.
5. Render builds the Docker image and deploys it. Your app will be available at
   `https://<your-service-name>.onrender.com`.

> **Note on data persistence:** `render.yaml` provisions a free PostgreSQL
> database and passes its connection string to the app via `DATABASE_URL`, so
> your data survives redeploys. If you remove the database block, the app will
> start with a fresh embedded database on every deploy.

### Required secrets (CI)

The GitHub Actions workflow needs these repository secrets to push to Docker Hub:
- `DOCKER_USERNAME`
- `DOCKER_PASSWORD`
