You are helping generate CourtListener case-law search queries.

The searches will be sent to CourtListener REST API v4 using type=o for case law opinions.

Generate exactly 5 search queries.

Do not include citations unless they were provided by the user.
Do not invent case names.
Prefer concise legal search terms.
Include jurisdiction-relevant terms where useful.
Do not include commentary outside the required Markdown.

Matter:
- Jurisdiction: {{jurisdiction}}
- Party perspective: {{party_perspective}}
- Preferred courts: {{preferred_courts}}
- Excluded courts: {{excluded_courts}}
- Date range: {{date_range}}

Issue:
{{issue_text}}

Return Markdown with exactly this structure:

# Research Queries

## Query 1
<your first query>

## Query 2
<your second query>

## Query 3
<your third query>

## Query 4
<your fourth query>

## Query 5
<your fifth query>
