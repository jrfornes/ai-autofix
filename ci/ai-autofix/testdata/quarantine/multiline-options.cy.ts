describe('quarantine fixture', () => {
  it(
    'multiline options title',
    {
      retries: 1,
    },
    () => {
      cy.get('body');
    }
  );
});
