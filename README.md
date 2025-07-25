# Repository Configuration Analyzer

This project provides a powerful shell script, `process_repository.sh`, that automates the analysis of application configurations within any specified GitHub repository under the Meesho organization. It clones the repository, uses `repomix` to generate a summary, analyzes the configuration files with the Gemini AI, and uploads the resulting CSV report to a secure Google Cloud Storage (GCS) bucket.

## Features

- **Automated Dependency Management**: Automatically installs required tools like `jq`, `nodejs`, and the `gcloud` CLI if they are not already present.
- **Secure Authentication**: Uses environment variables for `GITHUB_TOKEN`, `GEMINI_API_KEY`, and a `GCS_SERVICE_ACCOUNT_KEY_PATH` for secure, non-interactive execution.
- **AI-Powered Analysis**: Leverages the Gemini 1.5 Pro model to perform a detailed analysis of `application-dyn-{env}.yml` files, extracting key-value pairs and other relevant metadata.
- **Secure Cloud Storage**: Uploads the final CSV report to a GCS bucket and restricts access to users within the `meesho.com` domain.
- **CI/CD Ready**: Designed to be run in automated environments like Jenkins, with features that support parameterization and secure credential management.

## Prerequisites

Before you begin, ensure you have the following:

1.  **Git**: Required for cloning repositories.
2.  **Google Cloud Account**: You will need a Google Cloud project to create a service account and a GCS bucket.
3.  **Gemini API Key**: An API key for the Gemini service. You can get one from [Google AI Studio](https://aistudio.google.com/app/apikey).
4.  **GitHub Personal Access Token**: A token with repository access permissions for the Meesho organization.

## Setup

Follow these steps to configure the script for its first run:

### 1. Create the `.env` File

Create a file named `.env` in the root of the project. This file will store your secret keys and authentication details.

### 2. Add Environment Variables

Add the following environment variables to your `.env` file:

```bash
# Your GitHub Personal Access Token with repo access
GITHUB_TOKEN="ghp_YourGitHubPersonalAccessTokenHere"

# Your API key for the Gemini service
GEMINI_API_KEY="AIzaSy_YourGeminiApiKeyHere"

# The absolute path to your Google Cloud service account key
GCS_SERVICE_ACCOUNT_KEY_PATH="/path/to/your/gcs-service-account-key.json"
```

### 3. Set Up GCS Service Account

1.  **Create a Service Account**: Go to the [Service Accounts page](https://console.cloud.google.com/iam-admin/serviceaccounts) in the Google Cloud Console and create a new service account.
2.  **Grant Permissions**: Grant the service account the **Storage Object Creator** role on your project. This will allow it to write files to your GCS bucket.
3.  **Download the Key**: Create and download a JSON key for the service account. Save this file to a secure location on your machine.
4.  **Update `.env`**: Make sure the `GCS_SERVICE_ACCOUNT_KEY_PATH` in your `.env` file points to the correct location of the JSON key you just downloaded.

## Usage

Once the setup is complete, you can run the script by providing a repository name as an argument. The script is located in the `scripts` directory.

```bash
./scripts/process_repository.sh <repository-name>
```

**Example:**

```bash
./scripts/process_repository.sh comms-recommendation
```

The script will then execute all the steps, and if successful, it will print a link to the generated CSV file in your GCS bucket.

## How It Works

1.  **Dependency Check**: The script first checks for `jq`, `npx`, and `gcloud`. If any are missing, it attempts to install them using the appropriate system package manager.
2.  **Environment Loading**: It loads the necessary API keys and paths from the `.env` file.
3.  **Clone Repository**: It clones the `master` branch of the specified repository from the Meesho organization on GitHub.
4.  **Run Repomix**: It executes `npx repomix@latest` to generate an XML summary of the repository's structure.
5.  **Gemini Analysis**: It sends the XML content to the Gemini API with a detailed prompt, asking it to analyze the `application-dyn-{env}.yml` files and return a CSV.
6.  **GCS Upload**: The script authenticates with Google Cloud using the service account, uploads the CSV to the `dynamic-configs-audit` bucket, and sets permissions so that it's only accessible to users in the `meesho.com` domain.
7.  **Log Link**: Finally, it logs a secure link to the uploaded file.
