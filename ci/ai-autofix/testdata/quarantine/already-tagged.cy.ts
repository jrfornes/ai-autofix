describe('quarantine fixture', () => {
  it('already tagged title', { tags: ['@flaky'] }, () => {
    cy.get('body');
  });
});
