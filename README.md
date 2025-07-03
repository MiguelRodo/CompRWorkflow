# README

This repository provides infastructure for the project to _[Briefly describe the aims and context of the analysis or research project here.]_

See [Workspace setup](#workspace-setup) for details on how to set up a [multi-repository R-based development environment](#multi-repository-workflow) and a [containerised development environment](#r-development-container) for this project.

## Contact

For more information, please contact:  
- [Name], [Email Address]  
- [Name], [Email Address]

## Links

- [URLs to data sources (e.g. OneDrive), GitHub repositories, publications, etc.]

## Details

[Methods, timeline, team, data sources, software/tools, etc.]

## Workspace setup

This repository provides infrastructure for a multi-repository R-based research project.
It can be used both to **set up a containerised development environment** and to **manage a VS Code workspace spanning multiple repositories** — both of which are optional.

<!--

You may use this repository:

- as part of an existing project, to quickly reproduce or continue analysis, or  
- as a starting point for new projects with similar infrastructure needs.

!-->

### Multi-repository workflow

This repo supports easy setup of a multi-repository workspace on Linux, macOS or Windows.

1. **Specify repositories**  
   Edit `repos.list` in the root. See its header for format details.

2. **Clone repositories**  
   ```bash
   scripts/clone-repos.sh
   ```

  * Works on any OS with Git.
  * On Windows, run in Git Bash (from Git for Windows).

3. **Create a VS Code workspace (optional)**

   ```bash
   scripts/vscode-workspace-add.sh
   ```

   * Requires any version of `Python` or the `jq` utility.
   * Then in VS Code: **File → Open Workspace from File…** → select `entire-project.code-workspace`.

### R development container

A ready-to-use devcontainer config is provided under `.devcontainer/devcontainer.json`.

#### Base image

* By default, the Dockerfile starts with

  ```dockerfile
  FROM bioconductor/bioconductor_docker:RELEASE_3_20
  ```

  which gives you pre-built Bioconductor binaries.
* To pick another Bioconductor release, change that `FROM` line (e.g. `RELEASE_3_19` instead of `RELEASE_3_20`).
* To use a non-Bioconductor base (e.g. `rocker/r-verse:4.4`), update the same `FROM` line accordingly.

#### Features

The devcontainer includes:

* **Quarto** (with TinyTeX)
* Common Ubuntu packages for R/data science
* **radian**, a modern R console
* A **repos** feature to clone repos specified in `repos.list`. Important primarily for GitHub Codespaces, as it overrides default `Codespaces` Git authentication. Ensure that the environment variable `GH_TOKEN` is available as a Codespaces secret, and that it has permissions to clone the specified repositories.
* A **config-r** feature that pre-installs packages from any `.devcontainer/renv/<dir>/renv.lock` into the global cache for faster container starts once built. Multiple `<dir>`s can be specified to install packages from multiple lockfiles.

#### Automated builds

A GitHub Actions workflow (`.github/workflows/devcontainer-build.yml`) will:

* Build the container on each push to `main` (or via manual dispatch).
* Push images to GitHub Container Registry (`ghcr.io`) tagged by repo and branch.
* Generate `.devcontainer/prebuild/devcontainer.json` pointing to the latest pre-built image, so VS Code can open almost instantly.

To disable automatic builds, remove or comment out the `on.push` section in that workflow file.

#### Dotfiles

If running within a container, then typically additional configuration is convenient.
For example, `radian` on Linux works poorly unless the option `auto_match` is set to `false`.

A convenient way to say this is up is to use the `SATVILab/dotfiles` repository.
After opening this repository in a container, run the following command:

```bash
git clone https://github.com/SATVILab/dotfiles.git "$HOME"/dotfiles
"$HOME"/dotfiles/install-env.sh dev
```

See `https://github.dev/SATVILab/dotfiles` for more information on the dotfiles repository.
