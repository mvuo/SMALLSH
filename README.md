# SMALLSH
> Implements a command line interface similar to well-known shells, such as bash.


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

