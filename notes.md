

# DONE: Sane git histoy

Take a different branch of upstream for each major change: Marked Buffers, Prompt Caching, and Dan Debug

 - [X] Update Markedbuffers branch

### How I did it:

 - [X] Research how to make a git branch within a rebase todo
 - [X] Save main as main_pre_rebase -- this is gold standard
 - [X] Use `git rebase --rebase-merges` to create an interactive rebase that:
   a. Save upstream
   b. Play back logging and comment and vader commits, reordered for clarity
   c. Squash all
   c. interactive add into logging and comment and vader commits
   d. Create new development branch
   e. Rewind to upstream
   f. Merge branches into main:
     1. MarkedBuffers
     2. Prompt Caching
     3. Devel Branch
 - [X] Compare with main_pre_rebase, fixup as necessary
   a. Apply any missing changes. Slide them into feature branches if needed

 - [ ] When upstream changes, be prepared to rebase main by doing the equivalent of 3.e and 3.f
    - Use git rebase --rebase-merges to do this


# DONE: Update Buffer Marking for PR Comments

### Issues

 I'm stuck because the existing API under ClaudeImplement does stuff in the claude window but only if it is open??

   - And I want to know whether to adopt its convention.
   - So lets's look at Claudeimplment. It calls ClaudeQueryInternal with the selection and no additional context. StreamingImplementResponse and FinalImplementResponse are the callbacks 
   - It uses LogImplementInChat, which only logs if the chat window is open, so no dependency on chat window

   - For ClaudeChat, calls ClaudeQueryInternal with  StreamingChatResponse, which expects to be able to go to the claude window and use setline/etc

### Decision
   - Option 1: For buffer marking from another tab, need to update offscreen buffers so use vim8 api and buffer number to do this. 
     - Also do this for getsection / mksection
   - Option 2: For buffer marking from another tab, update GetOrCreateChatWindow to make the window visible and then switch to it using WithOutputPane()

## Action
  - Make OpenClaudeChat create an "Included Buffers" section.
  - Make AddSection take vimscript 8 numbered buffers

  - FIXME: Make  `GetOrCreateChatWindow` expose the chat window if not visible. Right now it returns -1 for win id, which goes badly if buffer is loaded but not visible

  

vim: ts=4 sw=4 et ai
