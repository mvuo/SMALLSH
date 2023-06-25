# SMALLSH
> Implements a command line interface similar to well-known shells, such as bash, using C.


## Table of Contents
* [General Info](#general-information)
* [Technologies Used](#technologies-used)
* [Features](#features)
* [Screenshots](#screenshots)
* [Setup](#setup)
* [Usage](#usage)
* [Project Status](#project-status)
* [Room for Improvement](#room-for-improvement)
* [Acknowledgements](#acknowledgements)
* [Contact](#contact)
<!-- * [License](#license) -->


## General Information
This program will
- Print an interactive input prompt
- Parse command line input into semantic tokens
- Implements parameter expansion (Shell special parameters $$, $?, and $!
- Implement two shell built-in commands: exit and cd
- Executes non-built-in commands using the appropriate EXEC(3) function (Implement redirection operators '<', '>', and '>>')
- Implements custom behavior for SIGINT and SIGTSTP signals



## Technologies Used
- Bash or similar command line interface to run


## Features
The following steps will be performed in an infinte loop where appropriate
- Input
- Word Splitting
- Expansion
- Parsing
- Execution
- Waiting

The loop is exited when the built-in exit command is executed or when the end of input is reached. End of input will be interpreted as an implied exit $? command (i.e. smallsh exits with the status of the last foreground command as its own exit status).
Smallsh can be invoked with no arguments, in which case it reads commands from stdin, or with one argument, in which case the argument specifies the name of a file (script) to read commands from. These will be referred to as interactive and non-interactive mode, respectively.
In non-interactive mode, smallsh should open its file/script with the CLOEXEC flag, so that child processes do not inherit the open file descriptor.
Whenever an explicitly mentioned error occurs, an informative message shall be printed to stderr and the value of the “$?” variable shall be set to a non-zero value. Further processing of the current command line shall stop and execution shall return to step 1. All other errors and edge cases are unspecified.

## Screenshots
See attached mkv video for preview.


## Setup
What are the project requirements/dependencies? Where are they listed? A requirements.txt or a Pipfile.lock file perhaps? Where is it located?

Proceed to describe how to install / setup one's local environment / get started with the project.


## Usage
Download and extract files. Navigate to where files are downloaded in command line and type 'make'. From there, the program can be run by typing ./smallsh


## Project Status
Project is: _complete_ 


## Room for Improvement
N/A

Room for improvement:
- Could further implement more complex functionality of shell.

## Acknowledgements
- This project was inspired by OSU cs344 class



## Contact
Created by Michael Vuong, https://github.com/mvuo - feel free to contact me!

