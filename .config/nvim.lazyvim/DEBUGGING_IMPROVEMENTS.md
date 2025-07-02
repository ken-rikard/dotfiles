# .NET Debugging Configuration Improvements

## Overview
Enhanced the .NET debugging configuration in `ken-dap.lua` with comprehensive improvements for better development experience.

## Key Improvements

### 1. Enhanced Project Detection
- **Multi-project support**: Automatically detects all `.csproj` files in the workspace
- **Target framework detection**: Reads `TargetFramework` and `TargetFrameworks` from project files
- **Project type detection**: Identifies web applications, console apps, and test projects
- **Output type detection**: Recognizes different output types (Exe, Library, etc.)

### 2. Improved DLL Selection Logic
- **Smart sorting**: Project DLLs are prioritized over dependencies
- **Framework-specific paths**: Searches in `bin/Debug/{framework}/` and `bin/Release/{framework}/` directories
- **System DLL filtering**: Automatically excludes Microsoft, System, and test-related DLLs
- **Better UI**: Enhanced Telescope picker with relative paths and clear descriptions

### 3. Multiple Debug Configurations
- **Launch .NET Application (DLL)**: Direct DLL execution with intelligent selection
- **Launch with dotnet run**: Uses `dotnet run` command with project selection
- **Attach to .NET Process**: Lists and attaches to running .NET processes
- **Debug .NET Tests**: Automatically detects and debugs test projects

### 4. Environment Variable Support
- **launchSettings.json integration**: Automatically reads environment variables from `Properties/launchSettings.json`
- **Profile detection**: Identifies launch profiles for web applications
- **Dynamic environment loading**: Applied to both DLL launch and dotnet run configurations

### 5. Advanced Project Analysis
- **Web application detection**: Identifies ASP.NET Core applications
- **Test project detection**: Recognizes projects with `.Test` or `.Tests` in the name
- **Entry point detection**: Finds `Program.cs`, `Main.cs`, or files with Main methods
- **Multi-target framework support**: Handles projects with multiple target frameworks

## Configuration Structure

### Available Debug Configurations
1. **Launch .NET Application (DLL)**
   - Directly launches compiled DLL files
   - Smart project DLL selection
   - Environment variable support

2. **Launch with dotnet run**
   - Uses `dotnet run` command
   - Project selection for multi-project solutions
   - Inherits environment from launchSettings.json

3. **Attach to .NET Process**
   - Lists running .NET processes
   - Interactive process selection via Telescope

4. **Debug .NET Tests**
   - Automatically detects test projects
   - Supports multiple test projects
   - Uses `dotnet test` command

### Key Functions
- `find_project_root(path)`: Locates project root by searching for .csproj, .sln, or .git
- `get_project_info(project_root)`: Extracts comprehensive project information
- `find_dll_files(project_root)`: Intelligently locates compiled DLL files
- `get_dotnet_processes()`: Lists running .NET processes for attachment
- `find_project_entry_point(project_root)`: Identifies main entry points

## Usage

### Keybindings
- `<F5>`: Start/Continue debugging
- `<F9>`: Toggle breakpoint
- `<F10>`: Step over
- `<F11>`: Step into
- `<F8>`: Step out
- `<leader>dr`: Open REPL
- `<leader>dl`: Run last configuration
- `<space>?`: Evaluate expression

### Prerequisites
- netcoredbg installed at `/home/kenr/Documents/debuggers/netcoredbg/netcoredbg`
- nvim-dap and nvim-dap-ui plugins
- Telescope.nvim for enhanced selection UI

## Testing Instructions

1. **Basic functionality**: Open a .NET project and press `<F5>` to see available configurations
2. **DLL selection**: Build a project and test DLL selection with the first configuration
3. **dotnet run**: Test the second configuration for projects that can be run directly
4. **Process attachment**: Run a .NET application and test process attachment
5. **Test debugging**: Test the fourth configuration on a test project

## Benefits

- **Improved developer experience**: Intelligent project detection and selection
- **Multi-project support**: Works seamlessly with complex solutions
- **Environment consistency**: Respects launchSettings.json configurations
- **Flexible debugging options**: Multiple ways to start debugging sessions
- **Better error handling**: Clear notifications and fallback behaviors

