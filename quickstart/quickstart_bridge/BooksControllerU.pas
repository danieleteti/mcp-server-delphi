// ***************************************************************************
//
// MCP Bridge Quickstart — Demo REST controller
//
// Copyright (c) 2025-2026 Daniele Teti
//
// https://github.com/danieleteti/mcp-server-delphi
//
// Licensed under the Apache License, Version 2.0
//
// ***************************************************************************
//
// BOOKS CONTROLLER
// ================
// A minimal REST API used to demonstrate the MCPBridge feature.
// In a real project this would be replaced by your own controllers.
//
// Endpoints:
//   GET  /api/books              -> list all books (hard-coded demo data)
//   GET  /api/books/($id)        -> get one book by id
//   GET  /api/books/search?q=... -> search by keyword (returns empty results)
//   POST /api/books              -> echo-create (returns the body as received)
//
// ***************************************************************************
unit BooksControllerU;

interface

uses
  MVCFramework,
  MVCFramework.Commons;

type
  [MVCPath('/api/books')]
  TBooksController = class(TMVCController)
  public
    [MVCPath]
    [MVCHTTPMethod([httpGET])]
    [MVCDoc('Returns the list of all books')]
    procedure GetBooks;

    [MVCPath('/($id)')]
    [MVCHTTPMethod([httpGET])]
    [MVCDoc('Returns the book with the given id')]
    procedure GetBookById(const id: string);

    [MVCPath('/search')]
    [MVCHTTPMethod([httpGET])]
    [MVCDoc('Searches books by title keyword. Use limit to cap the result count (default 10)')]
    procedure SearchBooks(
      const [MVCFromQueryString('q')] q: string;
      const [MVCFromQueryString('limit', '10')] limit: Integer
    );

    [MVCPath]
    [MVCHTTPMethod([httpPOST])]
    [MVCDoc('Creates a new book. Send a JSON body with title and author fields')]
    procedure CreateBook(const [MVCFromBody] body: string);
  end;

implementation

uses
  System.SysUtils;

const
  BOOKS_JSON =
    '[' +
    '{"id":"1","title":"The Pragmatic Programmer","author":"Hunt & Thomas"},' +
    '{"id":"2","title":"Clean Code","author":"Robert C. Martin"},' +
    '{"id":"3","title":"Design Patterns","author":"Gang of Four"}' +
    ']';

procedure TBooksController.GetBooks;
begin
  Render(BOOKS_JSON);
end;

procedure TBooksController.GetBookById(const id: string);
begin
  // Delphi has no case-of on strings
  if id = '1' then
    Render('{"id":"1","title":"The Pragmatic Programmer","author":"Hunt & Thomas"}')
  else if id = '2' then
    Render('{"id":"2","title":"Clean Code","author":"Robert C. Martin"}')
  else if id = '3' then
    Render('{"id":"3","title":"Design Patterns","author":"Gang of Four"}')
  else
  begin
    ResponseStatus(404);
    Render('{"error":"Book not found","id":"' + id + '"}');
  end;
end;

procedure TBooksController.SearchBooks(const q: string; const limit: Integer);
begin
  Render(Format('{"q":"%s","limit":%d,"results":[]}', [q, limit]));
end;

procedure TBooksController.CreateBook(const body: string);
begin
  Render('{"created":true,"body":' + body + '}');
end;

end.
