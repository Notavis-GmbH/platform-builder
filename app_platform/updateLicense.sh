#!/bin/bash

# Function to update or add an environment variable in a .env file
update_env() {
    local file_path=$1
    local variable=$2
    local value=$3
    local temp_file=$(mktemp)

    if grep -q "^$variable=" "$file_path"; then
        # Variable found, update it
        sed "s/^$variable=.*/$variable=$value/" "$file_path" > "$temp_file"
    else
        # Variable not found, add it
        cp "$file_path" "$temp_file"
        echo "$variable=$value" >> "$temp_file"
    fi

    # Replace the original file with the temp file
    mv "$temp_file" "$file_path"
}

# Usage
# update_env "path/to/.env" "VARIABLE_NAME" "new_value"

# Example usage
update_env "/opt/app/.env" "APP_LICENSECODE" $1