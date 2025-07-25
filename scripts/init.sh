#!/bin/bash

# This script automates the process of analyzing a GitHub repository under Meesho. It performs the following steps:
# 1. Clones the default branch of a specified repository using a GITHUB_TOKEN.
# 2. Runs 'repomix' to generate an XML summary of the repository structure.
# 3. Sends this summary to the Gemini AI API for analysis based on a detailed prompt.
# 4. Saves the AI-generated response into a CSV file named after the repository.
# 5. Uploads the report to a GCS bucket, restricted to the meesho.com domain.
# 6. Automatically installs dependencies (jq, nodejs, gcloud) if they are missing.
# 7. Cleans up the cloned repository after execution.

set -eo pipefail

# --- Argument Check ---
if [[ -z "$1" ]]; then
  echo "Usage: $0 <repository_name>"
  echo "Please provide a repository name as the first argument."
  exit 1
fi

# --- Configuration & Paths ---
REPO_NAME="$1"
OWNER="Meesho"
REPOSITORIES_DIR="repositories"
CLONE_PATH="$REPOSITORIES_DIR/$REPO_NAME"
OUTPUT_CSV="${REPO_NAME}.csv"
REPOMIX_FILE="repomix-output.xml"

# --- Cleanup ---
# This trap ensures that the cloned repository is removed when the script
# exits, either on success or failure.
cleanup() {
  echo
  echo "--- Cleaning up ---"
  if [ -d "$CLONE_PATH" ]; then
    echo "Removing cloned repository: $CLONE_PATH"
    rm -rf "$CLONE_PATH"
    echo "Cleanup complete."
  else
    echo "No repository directory to clean up."
  fi
}
trap cleanup EXIT

# --- Environment ---
# Automatically load environment variables from .env file if it exists.
if [ -f .env ]; then
  echo "Loading environment variables from .env file..."
  source .env
fi

# --- Dependency Management ---
# Checks for dependencies and installs them if they are missing.
install_dependency() {
  local cmd="$1"
  local package="$2"
  local install_cmd="$3"
  
  if ! command -v "$cmd" &> /dev/null; then
    echo "--- Dependency Check ---"
    echo "Required command '$cmd' not found. Attempting to install package '$package'..."
    
    # Execute the installation command
    # Using eval to handle multi-command strings
    eval "$install_cmd"
    
    # Verify installation
    if ! command -v "$cmd" &> /dev/null; then
      echo "Error: Failed to install '$package'. Please install it manually and rerun the script."
      exit 1
    fi
    echo "Successfully installed '$package'."
    echo "------------------------"
  fi
}

install_gcloud_apt() {
  sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates gnupg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list
  curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key --keyring /usr/share/keyrings/cloud.google.gpg add -
  sudo apt-get update && sudo apt-get install -y google-cloud-sdk
}

install_gcloud_yum() {
  sudo tee -a /etc/yum.repos.d/google-cloud-sdk.repo << EOM
[google-cloud-sdk]
name=Google Cloud SDK
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
       https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOM
  sudo yum install -y google-cloud-sdk
}

install_gcloud_dnf() {
  # For RHEL/CentOS 8 or later
  install_gcloud_yum
}


# Detect OS and install dependencies accordingly.
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS
  if ! command -v brew &> /dev/null; then
    echo "Error: Homebrew is not installed. Please install it to manage dependencies, or install 'jq' and 'node' manually."
    exit 1
  fi
  install_dependency "jq" "jq" "brew install jq"
  install_dependency "npx" "node" "brew install node"
  install_dependency "gcloud" "google-cloud-sdk" "brew install google-cloud-sdk"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
  # Linux
  if command -v apt-get &> /dev/null; then
    install_dependency "jq" "jq" "sudo apt-get update && sudo apt-get install -y jq"
    install_dependency "npx" "nodejs" "sudo apt-get install -y nodejs npm"
    install_dependency "gcloud" "google-cloud-sdk" "install_gcloud_apt"
  elif command -v yum &> /dev/null; then
    install_dependency "jq" "jq" "sudo yum install -y jq"
    install_dependency "npx" "nodejs" "sudo yum install -y nodejs"
    install_dependency "gcloud" "google-cloud-sdk" "install_gcloud_yum"
  elif command -v dnf &> /dev/null; then
    install_dependency "jq" "jq" "sudo dnf install -y jq"
    install_dependency "npx" "nodejs" "sudo dnf install -y nodejs"
    install_dependency "gcloud" "google-cloud-sdk" "install_gcloud_dnf"
  else
    echo "Error: Could not find a supported package manager (apt, yum, dnf). Please install 'jq', 'nodejs', and 'gcloud' manually."
    exit 1
  fi
else
  # Fallback for other operating systems. This just checks if the tools exist.
  if ! command -v jq &> /dev/null || ! command -v npx &> /dev/null || ! command -v gcloud &> /dev/null; then
    echo "Error: Unsupported OS. Please install 'jq', 'nodejs', and 'gcloud' manually."
    exit 1
  fi
fi

# --- Authentication ---
if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "Error: GITHUB_TOKEN environment variable is not set."
  echo "Please set it by running 'source .env' or exporting it manually."
  exit 1
fi

if [[ -z "$GEMINI_API_KEY" ]]; then
  echo "Error: GEMINI_API_KEY environment variable is not set."
  echo "Please set it by running 'source .env' or exporting it manually."
  exit 1
fi

if [[ -n "$GCS_SERVICE_ACCOUNT_KEY_PATH" && ! -f "$GCS_SERVICE_ACCOUNT_KEY_PATH" ]]; then
  echo "Error: GCS_SERVICE_ACCOUNT_KEY_PATH is set, but the file does not exist at that path."
  echo "Please verify the path in your .env file."
  exit 1
fi

REPO_URL="https://oauth2:$GITHUB_TOKEN@github.com/$OWNER/$REPO_NAME"

# --- Script ---

echo "---"
echo "Step 1: Processing Repository: $REPO_NAME"
echo "---"

# Create the 'repositories' directory if it doesn't exist.
mkdir -p "$REPOSITORIES_DIR"

# Clone the repository
if [ -d "$CLONE_PATH" ]; then
  echo "Repository already exists at $CLONE_PATH. Skipping clone."
else
  echo "Cloning the default branch..."
  git clone --progress "$REPO_URL" "$CLONE_PATH"
fi

# Create a repomix config file to exclude irrelevant files and reduce payload size.
REPOMIX_CONFIG_PATH="$CLONE_PATH/repomix.config.json"
echo "Creating repomix config at $REPOMIX_CONFIG_PATH..."
cat > "$REPOMIX_CONFIG_PATH" << EOL
{
  "exclude": [
    "**/node_modules/**",
    "**/dist/**",
    "**/build/**",
    "**/*.min.js",
    "**/*.svg",
    "**/*.png",
    "**/*.jpg",
    "**/*.jpeg",
    "**/*.gif",
    "**/*.webp",
    "**/*.ico",
    "**/*.pdf",
    "**/*.zip",
    "**/*.gz",
    "**/*.tar",
    "**/*.jar",
    "**/*.html",
    "**/docs/**"
  ]
}
EOL

# Run repomix inside a subshell to avoid changing the script's directory.
echo "Running 'npx repomix@latest'..."
(cd "$CLONE_PATH" && npx --yes repomix@latest)

if [ ! -f "$CLONE_PATH/$REPOMIX_FILE" ]; then
    echo "Error: repomix-output.xml was not found after running repomix."
    exit 1
fi
echo "'repomix-output.xml' generated successfully."

# --- AI Processing ---
echo
echo "---"
echo "Step 2: Sending data to Gemini for analysis"
echo "---"

REPOMIX_CONTENT_FILE="$CLONE_PATH/$REPOMIX_FILE"
PROMPT_TEMPLATE="Do the following steps until validation is successfull :
1. Analyze the content, find only the files that begin with application-dyn-{env}.yml and generate a CSV with 'Config key', 'Config Value', 'Environment', 'Application Profiles', 'Config Type', 'Config Value type', 'Current Usage' columns summarising the data. Here are the columns and their definitions:

Config key: The key of the config in the application-dyn-{env}.yml file.
Config Value: The value of the config in the application-dyn-{env}.yml file.
Environment: For a specific Application Profile, the environment of the config.
Application Profiles: List of the name of the spring profiles where it is used, keep "default" if not found.
Config Type: The type of the config, like "business", "common", "core", "infra", "security", "service", "ui", etc.
Config Value type: The type of the config value, like 'string', 'boolean', 'number', 'list', 'map', etc.
Current Usage: The current usage of the config in the content.

2. Group by the records by 'Config key', 'Config Value', 'Environment', 'Application Profiles', to avoid redundant information.
3. Validate each record in the CSV at least 3 times.

Note : only respond with the final content, do not include any other text.

Here is the content: "

# Safely create and pipe the JSON payload directly to curl.
# This avoids the "Argument list too long" error for large repositories.
# Temporarily disable exit-on-error to handle curl failures gracefully.
set +e
GEMINI_RESPONSE=$( \
    cat "$REPOMIX_CONTENT_FILE" | jq -R -s \
      --arg prompt_template "$PROMPT_TEMPLATE" \
      '{ "contents": [ { "parts": [ { "text": ($prompt_template + .) } ] } ] }' | \
    curl -s -w "\\nHTTP_STATUS_CODE:%{http_code}" \
         -H "Content-Type: application/json" \
         -d @- "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:generateContent?key=$GEMINI_API_KEY"
)
CURL_EXIT_CODE=$?
set -e # Re-enable exit-on-error

# Check if curl itself failed
if [ $CURL_EXIT_CODE -ne 0 ]; then
    echo "Error: curl command failed with exit code $CURL_EXIT_CODE."
    echo "This could be a network issue or an error in the curl command's syntax."
    exit 1
fi

# Extract the HTTP status code and the response body
HTTP_STATUS_CODE=$(echo "$GEMINI_RESPONSE" | tail -n1 | sed 's/HTTP_STATUS_CODE://')
RESPONSE_BODY=$(echo "$GEMINI_RESPONSE" | sed '$d')

# Check if the API call was successful
if [ "$HTTP_STATUS_CODE" -ne 200 ]; then
    echo "Error: Gemini API call failed with HTTP status $HTTP_STATUS_CODE."
    echo "This is often caused by an incorrect API key or an invalid model name."
    echo "API Response: $RESPONSE_BODY"
    exit 1
fi

GENERATED_CSV=$(echo "$RESPONSE_BODY" | jq -r '.candidates[0].content.parts[0].text')

if [ -z "$GENERATED_CSV" ] || [ "$GENERATED_CSV" == "null" ]; then
    echo "Error: Failed to get a valid response from Gemini, although the API call was successful."
    echo "Full Gemini response:"
    echo "$GENERATED_CSV"
    exit 1
fi

# Clean markdown formatting and check if the response contains more than just a header
CLEANED_CSV=$(echo "$GENERATED_CSV" | sed 's/^```csv//' | sed 's/^```//' | sed 's/```$//' | sed '/^[[:space:]]*$/d')
NUM_LINES=$(echo "$CLEANED_CSV" | wc -l)

if [ "$NUM_LINES" -le 1 ]; then
    echo "Warning: The response from Gemini appears to contain only a header or is empty."
    echo "This might mean no relevant configurations were found in the repository."
    echo "Full Gemini response:"
    echo "$GENERATED_CSV"
fi

echo "$CLEANED_CSV" > "$OUTPUT_CSV"

echo "Summary saved to $OUTPUT_CSV"

# 5. Upload to Google Cloud Storage
if command -v gcloud &> /dev/null && [[ -n "$GCS_SERVICE_ACCOUNT_KEY_PATH" ]]; then
  GCS_BUCKET="dynamic-configs-audit"
  echo
  echo "---"
  echo "Step 3: Uploading to Google Cloud Storage"
  echo "---"

  echo "Authenticating with GCS service account..."
  gcloud auth activate-service-account --key-file="$GCS_SERVICE_ACCOUNT_KEY_PATH"
  
  if [ $? -ne 0 ]; then
    echo "Error: Failed to authenticate with GCS. Please check your service account key."
    exit 1
  fi

  echo "Attempting to upload $OUTPUT_CSV to gs://$GCS_BUCKET..."
  gsutil cp "$OUTPUT_CSV" "gs://$GCS_BUCKET/"
  
  if [ $? -eq 0 ]; then
    echo "Successfully uploaded to gs://$GCS_BUCKET/$OUTPUT_CSV"
    
    # Log the console URL. Access is controlled by the bucket's IAM policy.
    CONSOLE_URL="https://storage.googleapis.com/$GCS_BUCKET/$OUTPUT_CSV"
    echo "Link : $CONSOLE_URL"

    echo "Removing local CSV file: $OUTPUT_CSV"
    rm "$OUTPUT_CSV"
  else
    echo "Error: Failed to upload to GCS. Please check your permissions and bucket name."
    exit 1
  fi
else
  echo "Skipping GCS upload because 'gcloud' is not installed or GCS_SERVICE_ACCOUNT_KEY_PATH is not set."
fi

echo "--- Script Finished ---" 